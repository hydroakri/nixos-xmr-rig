#!/usr/bin/env bash
# Interactive mining launcher: resolves the xmrig binary path dynamically
# (never hardcode the nix store path — it changes on every flake update/GC),
# only asks for sudo when perf tuning actually needs to change something,
# then starts XMRig. Safe to run repeatedly for on-demand start/stop.
set -uo pipefail
cd "$(dirname "$0")"

# On a real TTY, reserve the terminal's last row as a status bar right now,
# before anything is printed. DECSTBM (the scroll-region escape below) resets
# the cursor to the region's top-left as a side effect — doing this before
# any output means nothing is on screen yet to get overwritten by that
# reset. Everything printed from here on (these setup lines included) flows
# continuously within the confined region; only row N stays reserved.
IS_TTY=false
if [[ -t 1 ]]; then
    IS_TTY=true
    LINES_TOTAL=$(tput lines)
    # Clear first: DECSTBM below jumps the cursor to the screen's absolute
    # top-left regardless of where it was, so without a clear, whatever was
    # already on screen above the old cursor position gets overwritten.
    printf '\033[2J\033[H'
    printf '\033[1;%dr' "$((LINES_TOTAL - 1))"

    draw_status() {
        printf '\0337'
        printf '\033[%d;1H\033[K' "$LINES_TOTAL"
        printf '%s' "$1"
        printf '\0338'
    }

    cleanup_bar() {
        [[ -n "${STATUS_LOOP_PID:-}" ]] && kill "$STATUS_LOOP_PID" 2>/dev/null
        printf '\033[r'
        printf '\033[%d;1H\n' "$LINES_TOTAL"
    }
    trap cleanup_bar EXIT INT TERM
fi

echo "🔍 Resolving xmrig + sensors binary paths (nix develop)"
read -r XMRIG_STORE_BIN SENSORS_BIN < <(nix develop --command bash -c 'echo "$(readlink -f "$(which xmrig)") $(readlink -f "$(which sensors)")"')
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

# Force-enabled every run so configs generated before this existed also
# pick it up. Loopback-only + restricted:true — GET /1/summary works with
# no access-token, only write actions would need one. Scoped to just the
# "http" block (awk state machine, not a blind sed) — "enabled" and "port"
# both appear elsewhere in this file (cpu/opencl/cuda/pools[].enabled) and
# a global replace would wrongly flip those too.
XMRIG_API_PORT=18099
awk -v port="$XMRIG_API_PORT" '
/"http": *\{/ { in_http=1 }
in_http && /"enabled":/ { sub(/false/, "true") }
in_http && /"port":/ { sub(/[0-9]+/, port) }
in_http && /^[[:space:]]*\},?[[:space:]]*$/ { in_http=0 }
{ print }
' config.json > config.json.tmp && mv config.json.tmp config.json

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

# Direct first; if that's blocked, retry via local Tor SOCKS only if
# already present on this machine (no hard Tor dependency — a machine
# without it just gets the warning). Echoes the pool's raw JSON, empty on
# total failure. Shared by the live status bar loop below and the
# non-interactive one-shot fallback.
fetch_pool_stats_json() {
    local stats=""
    if [[ -n "${WALLET_ADDRESS:-}" ]]; then
        stats="$(curl -sL --max-time 6 "https://supportxmr.com/api/miner/${WALLET_ADDRESS}/stats" 2>/dev/null)"
        if [[ -z "$stats" ]] && timeout 1 bash -c 'echo > /dev/tcp/127.0.0.1/9050' 2>/dev/null; then
            stats="$(curl -sL --socks5-hostname 127.0.0.1:9050 --max-time 30 "https://supportxmr.com/api/miner/${WALLET_ADDRESS}/stats" 2>/dev/null)"
        fi
    fi
    echo "$stats" | grep -q '"amtDue"' && echo "$stats"
}

# Local, cheap, safe to poll every few seconds — xmrig's own loopback API
# and the sensors binary resolved earlier.
fetch_hashrate() {
    curl -s --max-time 2 "http://127.0.0.1:${XMRIG_API_PORT}/1/summary" 2>/dev/null \
        | grep -o '"total":\[[0-9.,null]*\]' | grep -oE '[0-9]+\.[0-9]+' | head -1
}

fetch_cpu_temp() {
    "$SENSORS_BIN" 2>/dev/null | grep -m1 -oE 'Tctl:[[:space:]]*\+?[0-9.]+' | grep -oE '[0-9.]+$'
}

echo "🚀 Starting XMRig"
# Backgrounded (not exec'd) so we can capture xmrig's actual PID for the
# gamemode registration below.
"$XMRIG_BIN" -c config.json &
XMRIG_PID=$!

# `gamemoderun`'s usual trick is LD_PRELOAD-ing a constructor that
# self-registers with gamemoded — but ld.so ignores LD_PRELOAD/LD_LIBRARY_PATH
# for any binary carrying file capabilities (same class of protection as the
# nosuid mount stripping capabilities above, just enforced by the dynamic
# linker instead of the kernel), so it silently never fires on $XMRIG_BIN.
# Register xmrig's actual PID (captured above) directly over D-Bus instead —
# same effect, no LD_PRELOAD involved. gamemoded's reaper thread
# auto-unregisters it a few seconds after the process exits.
echo "🎮 Registering with gamemoded via D-Bus (CPU governor -> performance, I/O priority boost)"
if busctl --user call com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode RegisterGame i "$XMRIG_PID" >/dev/null 2>&1; then
    echo "   ✅ registered PID $XMRIG_PID with gamemoded"
else
    echo "⚠️  gamemode registration failed, continuing without" >&2
fi

if [[ "$IS_TTY" == true ]]; then
    (
        # Hashrate + temp are local and cheap — refreshed every tick (10s).
        # Pool data needs a network round-trip and shouldn't be hammered —
        # refreshed every 30th tick (~5 min). ETA to the 0.1 XMR payout
        # threshold comes from the delta between consecutive pool readings,
        # no extra requests needed for it.
        POOL_PART="fetching pool data..."
        PREV_DUE=""
        PREV_TIME=""
        TICK=0
        while true; do
            HASHRATE="$(fetch_hashrate)"
            TEMP="$(fetch_cpu_temp)"

            if (( TICK % 30 == 0 )); then
                STATS_JSON="$(fetch_pool_stats_json)"
                if [[ -n "$STATS_JSON" ]]; then
                    DUE=$(echo "$STATS_JSON" | grep -o '"amtDue":[0-9]*' | grep -o '[0-9]*')
                    PAID=$(echo "$STATS_JSON" | grep -o '"amtPaid":[0-9]*' | grep -o '[0-9]*')
                    SHARES=$(echo "$STATS_JSON" | grep -o '"validShares":[0-9]*' | grep -o '[0-9]*')
                    NOW=$(date +%s)
                    ETA_TEXT="calculating..."
                    if [[ -n "$PREV_DUE" && "$DUE" -gt "$PREV_DUE" ]]; then
                        ETA_TEXT="$(awk -v due="$DUE" -v prev="$PREV_DUE" -v now="$NOW" -v prevt="$PREV_TIME" 'BEGIN {
                            rate = (due - prev) / (now - prevt)
                            target = 100000000000
                            remain = target - due
                            if (rate <= 0 || remain <= 0) { print "n/a"; exit }
                            secs = remain / rate
                            d = int(secs / 86400); secs -= d * 86400
                            h = int(secs / 3600); secs -= h * 3600
                            m = int(secs / 60)
                            if (d > 0) printf "%dd %dh", d, h
                            else if (h > 0) printf "%dh %dm", h, m
                            else printf "%dm", m
                        }')"
                    fi
                    PREV_DUE="$DUE"
                    PREV_TIME="$NOW"
                    POOL_PART="$(awk -v due="${DUE:-0}" -v paid="${PAID:-0}" -v shares="${SHARES:-0}" -v eta="$ETA_TEXT" 'BEGIN {
                        printf "Pending: %.8f | Paid: %.8f | Shares: %s | ETA: %s", due/1e12, paid/1e12, shares, eta
                    }')"
                else
                    POOL_PART="⚠️  pool unreachable (direct blocked, no local Tor)"
                fi
            fi
            TICK=$((TICK + 1))

            draw_status "🌡️ ${TEMP:-N/A}°C | ⚡ ${HASHRATE:-N/A} H/s | ${POOL_PART}"
            sleep 10
        done
    ) &
    STATUS_LOOP_PID=$!
else
    STATS_JSON="$(fetch_pool_stats_json)"
    if [[ -n "$STATS_JSON" ]]; then
        DUE=$(echo "$STATS_JSON" | grep -o '"amtDue":[0-9]*' | grep -o '[0-9]*')
        PAID=$(echo "$STATS_JSON" | grep -o '"amtPaid":[0-9]*' | grep -o '[0-9]*')
        SHARES=$(echo "$STATS_JSON" | grep -o '"validShares":[0-9]*' | grep -o '[0-9]*')
        awk -v due="${DUE:-0}" -v paid="${PAID:-0}" -v shares="${SHARES:-0}" 'BEGIN {
            printf "📊 XMR Pending: %.8f | XMR Paid: %.8f | Valid shares: %s\n", due/1e12, paid/1e12, shares
        }'
    else
        echo "⚠️  couldn't reach the pool's API (direct blocked, no local Tor)" >&2
    fi
fi

wait "$XMRIG_PID"
