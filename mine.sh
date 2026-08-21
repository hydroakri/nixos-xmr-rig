#!/usr/bin/env bash
# Interactive mining launcher: resolves the xmrig binary path dynamically
# (never hardcode the nix store path — it changes on every flake update/GC),
# only asks for sudo when perf tuning actually needs to change something,
# then starts XMRig. Safe to run repeatedly for on-demand start/stop.
set -uo pipefail
cd "$(dirname "$0")"

echo "🔍 Resolving xmrig binary path (nix develop)"
XMRIG_STORE_BIN="$(nix develop --command bash -c 'readlink -f "$(which xmrig)"')"
if [[ -z "$XMRIG_STORE_BIN" ]]; then
    echo "❌ Failed to resolve xmrig path" >&2
    exit 1
fi
echo "   $XMRIG_STORE_BIN"

# sudo on this box is a doas shim and doesn't support `sudo -v` credential
# probing/caching, so each privileged command is called individually. If
# this script is already running as root (e.g. launched via sudo/doas),
# skip the extra sudo wrapper.
if [[ "$(id -u)" -eq 0 ]]; then
    PRIV=()
else
    PRIV=(sudo)
fi

# /nix/store is read-only, so we can't setcap a file that lives there.
# /home is mounted nosuid on this machine — the kernel silently strips file
# capabilities on exec for anything under a nosuid mount, so a writable
# copy *inside the project dir* would never actually get the capability at
# runtime even though `getcap` shows it's set. /var/lib isn't its own mount
# here — it's just a directory on the root filesystem, which IS suid-capable
# (this box's `/` is an ephemeral tmpfs wiped on reboot, so this directory
# needs recreating after every reboot anyway — same lifecycle as the huge
# pages reservation below).
BINARY_DIR="/var/lib/xmr-mining"
if [[ ! -d "$BINARY_DIR" ]] || [[ "$(stat -c %U "$BINARY_DIR" 2>/dev/null)" != "$(id -un)" ]]; then
    "${PRIV[@]}" mkdir -p "$BINARY_DIR"
    "${PRIV[@]}" chown "$(id -un):$(id -gn)" "$BINARY_DIR"
    echo "   📁 created $BINARY_DIR (owned by $(id -un))"
fi
XMRIG_BIN="$BINARY_DIR/xmrig"
NEED_SETCAP=false
if ! cmp -s "$XMRIG_STORE_BIN" "$XMRIG_BIN" 2>/dev/null; then
    cp -f "$XMRIG_STORE_BIN" "$XMRIG_BIN"
    chmod +x "$XMRIG_BIN"
    NEED_SETCAP=true
    echo "   📦 binary changed, re-copied to writable path: $XMRIG_BIN"
else
    echo "   📦 up to date: $XMRIG_BIN"
fi

if [[ ! -f config.json ]]; then
    cp config.json.example config.json
    echo "📄 Created config.json from config.json.example (config.json is gitignored — it ends up holding your real wallet address)"
fi

echo "💰 Injecting wallet address from wallet-address.local (kept out of git — config.json.example only ever holds a placeholder)"
WALLET_ADDRESS_FILE="wallet-address.local"
if [[ -f "$WALLET_ADDRESS_FILE" ]]; then
    WALLET_ADDRESS="$(tr -d '[:space:]' < "$WALLET_ADDRESS_FILE")"
    sed -i -E "s/\"user\": *\"[^\"]*\"/\"user\": \"${WALLET_ADDRESS}\"/" config.json
    echo "   ✅ wallet address injected"
else
    echo "❌ $WALLET_ADDRESS_FILE not found — put your Monero address in it (one line, nothing else)" >&2
    exit 1
fi

echo "🌐 Resolving pool IP via Quad9 unfiltered DoH (bypasses local sing-box blocklist + Quad9's own default-node filtering)"
# sing-box's hijack-dns intercepts every plain DNS query (port 53 / DNS
# protocol) system-wide, so even querying 8.8.8.8/1.1.1.1 directly gets
# answered locally. DoH (HTTPS/443) isn't sniffed as DNS traffic, and the
# query is inside TLS, so sing-box can't see which domain we're asking
# about. Use 9.9.9.10 (Quad9's unfiltered node — the default 9.9.9.9 node
# blocks this domain too via its own threat-intel feed).
POOL_DOMAIN="pool.supportxmr.com"
POOL_PORT="443"
RESOLVED_IP="$(dig +https +short A "$POOL_DOMAIN" @9.9.9.10 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
if [[ -n "$RESOLVED_IP" ]]; then
    sed -i -E "s/\"url\": *\"[0-9.]+:${POOL_PORT}\"/\"url\": \"${RESOLVED_IP}:${POOL_PORT}\"/" config.json
    echo "   ✅ pool IP refreshed to ${RESOLVED_IP} (${POOL_DOMAIN})"
else
    echo "⚠️  Quad9 unfiltered DoH lookup failed, keeping the IP already in config.json" >&2
fi

echo "⚡ Checking huge pages + MSR tuning (RandomX perf boost, safe to skip)"
# Only touch privileged state that isn't already in the desired shape —
# this is what makes repeat "start mining" runs need zero sudo prompts
# (huge pages persist system-wide until reboot; the capability persists on
# the binary until it's overwritten).

# RandomX dataset needs 1168x 2MB pages (2336MB) + 8 more for the 8 mining
# threads' scratchpads (2MB each) = 1176 minimum. 1280 leaves headroom.
HUGEPAGES=1280
CURRENT_HUGEPAGES="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
if [[ "$CURRENT_HUGEPAGES" -ge "$HUGEPAGES" ]]; then
    echo "   ✅ huge pages already at ${CURRENT_HUGEPAGES} (>= ${HUGEPAGES}), skipping"
elif "${PRIV[@]}" sysctl -w "vm.nr_hugepages=${HUGEPAGES}"; then
    echo "   ✅ huge pages set to ${HUGEPAGES}"
else
    echo "⚠️  failed to set huge pages, continuing without" >&2
fi

# /dev/cpu/*/msr is mode 0600 root:root — cap_sys_rawio alone lets xmrig
# past the driver's internal capability check, but open() still hits the
# plain file-permission (DAC) check first and fails. cap_dac_override lets
# it bypass file permissions generally, not just for /dev/cpu/*/msr — that's
# a real, broader privilege on this one binary if it's ever compromised.
if [[ "$NEED_SETCAP" == false ]] && getcap "$XMRIG_BIN" 2>/dev/null | grep -q "cap_dac_override.*cap_sys_rawio\|cap_sys_rawio.*cap_dac_override"; then
    echo "   ✅ MSR capabilities already set on $XMRIG_BIN, skipping"
elif "${PRIV[@]}" setcap cap_sys_rawio,cap_dac_override+ep "$XMRIG_BIN"; then
    echo "   ✅ granted MSR write capabilities (cap_sys_rawio + cap_dac_override)"
else
    echo "⚠️  setcap failed, continuing without (hashrate will be slightly lower)" >&2
fi

echo "🎮 Starting XMRig under gamemoderun (CPU governor -> performance, I/O/process priority boost)"
exec gamemoderun "$XMRIG_BIN" -c config.json
