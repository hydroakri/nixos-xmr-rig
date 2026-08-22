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
        [[ -n "${CONTROL_LOOP_PID:-}" ]] && kill "$CONTROL_LOOP_PID" 2>/dev/null
        printf '\033[r'
        printf '\033[%d;1H\n' "$LINES_TOTAL"
    }
    trap cleanup_bar EXIT INT TERM
fi

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

# One representative logical CPU per physical core (lowest-numbered of each
# thread_siblings_list group) — RandomX doesn't benefit from SMT/hyperthreads
# (two logical threads sharing one core's L2 fight over cache), so any
# thread-count array we build should stay within this list, not a naive
# sequential 0..N-1 that would start doubling up on SMT sibling pairs past
# the physical core count. Portable across x86/ARM; falls back to plain
# `nproc` (best-effort, may include SMT siblings) if the topology files
# aren't there.
PHYSICAL_CORE_LIST="$(
    for f in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
        cpu="$(echo "$f" | grep -oE 'cpu[0-9]+' | grep -oE '[0-9]+')"
        echo "$(cat "$f" 2>/dev/null) $cpu"
    done 2>/dev/null | sort -t' ' -k1,1V -k2,2n | awk '!seen[$1]++ {print $2}' | sort -n | paste -sd, -
)"
if [[ -z "$PHYSICAL_CORE_LIST" ]]; then
    PHYSICAL_CORE_LIST="$(seq -s, 0 $(($(nproc) - 1)))"
fi
PHYSICAL_CORE_COUNT="$(echo "$PHYSICAL_CORE_LIST" | tr ',' '\n' | wc -l)"

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
sed -i -E "s/\"rig-id\": *\"[^\"]*\"/\"rig-id\": \"$(hostname)\"/" config.json

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
    sed -i -E "s/\"url\": *\"[^\"]*:${POOL_PORT}\"/\"url\": \"${RESOLVED_IP}:${POOL_PORT}\"/" config.json
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

# Force-disabled every run too — xmrig's autosave would otherwise write
# back per-host thread arrays on exit, and a config.json from before this
# was set to false in config.json.example may still have it on. "autosave"
# is a unique top-level key, safe for a plain sed (no block-scoping needed).
sed -i -E 's/"autosave": *true/"autosave": false/' config.json

# Optional local override — gitignored, like wallet-address.local. Absent
# by default: every physical core, full priority (see MINE_THREADS below).
MINE_THREADS=""
MINE_RANDOMX_MODE=""
MINE_HUGEPAGES=""
MINE_CPU_PRIORITY=""
if [[ -f mining-profile.local ]]; then
    # shellcheck disable=SC1091
    source mining-profile.local
    echo "⚙️  Loaded mining-profile.local (threads=${MINE_THREADS:-all}, randomx-mode=${MINE_RANDOMX_MODE:-auto}, huge-pages=${MINE_HUGEPAGES:-auto}, cpu-priority=${MINE_CPU_PRIORITY:-default})"
fi

# Always every physical core unless a profile explicitly caps it — no
# load-based reduction. If this host has other important work running on
# it, cap MINE_THREADS in mining-profile.local; nothing here defers
# automatically.
if [[ -z "$MINE_THREADS" ]]; then
    MINE_THREADS="$PHYSICAL_CORE_COUNT"
fi

# Decide fast vs light ourselves (from available RAM) instead of leaving
# randomx.mode at xmrig's own "auto" — we're not confident enough in
# exactly how conservative that internal heuristic is (never verified
# against a real low-RAM host) to size huge pages against an unknown. This
# also means the huge-pages math below is always sized for the mode that
# actually gets used, never guessing.
if [[ -z "$MINE_RANDOMX_MODE" ]]; then
    MEM_AVAILABLE_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
    if [[ -n "$MEM_AVAILABLE_MB" && "$MEM_AVAILABLE_MB" -lt 3072 ]]; then
        MINE_RANDOMX_MODE="light"
    else
        MINE_RANDOMX_MODE="fast"
    fi
    echo "   🔍 auto-detected randomx-mode: ${MINE_RANDOMX_MODE} (${MEM_AVAILABLE_MB:-unknown}MB available, <3072MB picks light)"
fi

# Auto-size huge pages from thread count + the RandomX mode resolved above,
# unless the profile set an explicit number (0 included, to disable).
# RandomX's shared allocation is fixed regardless of thread count — fast
# mode's dataset+JIT is 1168x 2MB pages (2336MB), light mode's cache is
# 128x 2MB pages (256MB) — plus one 2MB scratchpad page per thread, which
# does scale with thread count.
if [[ -z "$MINE_HUGEPAGES" ]]; then
    if [[ "$MINE_RANDOMX_MODE" == "light" ]]; then
        BASE_PAGES=128
    else
        BASE_PAGES=1168
    fi
    MINE_HUGEPAGES=$((BASE_PAGES + MINE_THREADS + 32))
fi

# Rewrites config.json's thread pin from $MINE_THREADS. Uses
# PHYSICAL_CORE_LIST (one logical CPU per physical core), never a naive
# sequential 0..N-1 — past the physical core count, sequential numbering
# starts doubling up on SMT sibling pairs, which is exactly what xmrig's
# own default avoids and RandomX doesn't benefit from. randomx.mode and
# cpu.priority are only ever set once (mode/priority don't change mid
# session, only thread count does), so those two are no-ops on later calls.
patch_thread_pin() {
    local core_list threads_line
    core_list="$(echo "$PHYSICAL_CORE_LIST" | cut -d, -f"1-${MINE_THREADS}")"
    threads_line="        \"rx\": [${core_list}],"
    awk -v threads_line="$threads_line" -v mode="$MINE_RANDOMX_MODE" -v prio="$MINE_CPU_PRIORITY" '
    /"cpu": *\{/ { in_cpu=1 }
    in_cpu && /"rx":/ { next }
    in_cpu && /"enabled": *true,?/ && threads_line != "" { print; print threads_line; next }
    in_cpu && /"priority":/ && prio != "" { sub(/null|[0-9]+/, prio) }
    in_cpu && /^[[:space:]]*\},?[[:space:]]*$/ { in_cpu=0 }
    /"randomx": *\{/ { in_rx=1 }
    in_rx && /"mode":/ && mode != "" { sub(/"mode": *"[a-z]+"/, "\"mode\": \"" mode "\"") }
    in_rx && /^[[:space:]]*\},?[[:space:]]*$/ { in_rx=0 }
    { print }
    ' config.json > config.json.tmp && mv config.json.tmp config.json
}
patch_thread_pin
echo "   ✅ config.json set to randomx-mode=${MINE_RANDOMX_MODE}, threads=${MINE_THREADS}${MINE_CPU_PRIORITY:+, cpu-priority=$MINE_CPU_PRIORITY}"

echo "⚡ Checking huge pages + MSR tuning (RandomX perf boost, safe to skip)"
# Only touch privileged state that isn't already in the desired shape —
# this is what makes repeat "start mining" runs need zero sudo prompts
# (huge pages persist system-wide until reboot; the capability persists on
# the binary until it's overwritten).
if [[ "$MINE_HUGEPAGES" -eq 0 ]]; then
    echo "   ⏭️  huge pages disabled via mining-profile.local, skipping"
    sed -i -E 's/"huge-pages": *true/"huge-pages": false/' config.json
else
    # MINE_HUGEPAGES was auto-sized above from this host's actual thread
    # count + RandomX mode (or came from an explicit profile override). Only
    # touch the reservation if it's too small, or wastefully large (>2x
    # what's needed now) — a prior session's fast-mode reservation left
    # sitting there after this one auto-detects light mode, say. The 2x
    # slack (not an exact match) is deliberate: small run-to-run swings in
    # the auto-detected thread count shouldn't trigger a resize — and
    # therefore a sudo prompt — on every single restart.
    CURRENT_HUGEPAGES="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
    if [[ "$CURRENT_HUGEPAGES" -ge "$MINE_HUGEPAGES" && "$CURRENT_HUGEPAGES" -lt $((MINE_HUGEPAGES * 2)) ]]; then
        echo "   ✅ huge pages already at ${CURRENT_HUGEPAGES} (fits ${MINE_HUGEPAGES} needed), skipping"
    elif "${PRIV[@]}" sysctl -w "vm.nr_hugepages=${MINE_HUGEPAGES}"; then
        if [[ "$CURRENT_HUGEPAGES" -gt "$MINE_HUGEPAGES" ]]; then
            echo "   ✅ huge pages reclaimed from ${CURRENT_HUGEPAGES} down to ${MINE_HUGEPAGES}"
        else
            echo "   ✅ huge pages set to ${MINE_HUGEPAGES}"
        fi
    else
        echo "⚠️  failed to set huge pages, continuing without" >&2
    fi
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

# /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq is root:root 0644 —
# chmod (not setfacl: sysfs doesn't actually persist POSIX ACLs, confirmed
# by setfacl reporting success while the write still failed — chmod tested
# and does work) grants this user write access one-time, like the
# capability above, so the thermal governor further down can turn the
# CPU's max clock up/down on its own later without needing a sudo prompt an
# unattended background loop can't provide. Only some drivers expose this
# knob (this box's amd-pstate-epp does); where it's missing, thermal
# response just quietly has nothing to act on below.
CPUFREQ_MAX_FILES=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq)
if [[ -e "${CPUFREQ_MAX_FILES[0]}" ]]; then
    if [[ -w "${CPUFREQ_MAX_FILES[0]}" ]]; then
        echo "   ✅ cpufreq scaling_max_freq already writable, skipping"
    elif "${PRIV[@]}" chmod a+w "${CPUFREQ_MAX_FILES[@]}" 2>/dev/null; then
        echo "   ✅ granted write access to cpufreq scaling_max_freq (thermal governor)"
    else
        echo "⚠️  couldn't grant cpufreq access, thermal response will be a no-op" >&2
    fi
fi
CPUFREQ_HW_MAX="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)"
CPUFREQ_HW_MIN="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo 0)"

# Writes $1 (kHz) to every core's scaling_max_freq — this, not thread-count
# reduction, is the thermal governor's actual lever: it caps clock speed
# under all currently-running threads instead of stopping some of them, so
# xmrig itself is never touched (no restart, no RandomX dataset re-init,
# no gap in hashing) — just runs cooler and a bit slower until temperature
# allows clocking back up.
set_cpu_max_freq() {
    local ok=true
    for f in "${CPUFREQ_MAX_FILES[@]}"; do
        echo "$1" > "$f" 2>/dev/null || ok=false
    done
    [[ "$ok" == true ]]
}

# Reset to full speed on every run regardless of what scaling_max_freq
# happens to currently be — a prior session's thermal throttle, a manual
# test, or anything else could have left it capped, and the control loop
# below assumes it's starting from CPUFREQ_HW_MAX. Silent no-op if not
# writable (already logged above) or the knob doesn't exist on this host.
if [[ -w "${CPUFREQ_MAX_FILES[0]:-/nonexistent}" && "$CPUFREQ_HW_MAX" -gt 0 ]]; then
    set_cpu_max_freq "$CPUFREQ_HW_MAX"
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

# Shared by both the live status bar loop and the non-interactive fallback
# below, instead of each re-deriving the same three fields independently.
parse_pool_field() {
    echo "$1" | grep -o "\"$2\":[0-9]*" | grep -o '[0-9]*'
}

# Local, cheap, safe to poll every few seconds — xmrig's own loopback API.
fetch_hashrate() {
    # xmrig's API JSON is pretty-printed with a space after the colon
    # ("total": [...], not "total":[...]) — matched that literally, not
    # against a synthetic guess, against a live instance's real output.
    curl -s --max-time 2 "http://127.0.0.1:${XMRIG_API_PORT}/1/summary" 2>/dev/null \
        | grep -o '"total": *\[[0-9., null]*\]' | grep -oE '[0-9]+\.[0-9]+' | head -1
}

fetch_cpu_temp() {
    # /sys/class/thermal is the generic Linux thermal framework — works on
    # x86 (ACPI) and ARM/RPi (SoC thermal zones) alike with zero extra
    # dependencies, unlike lm_sensors' AMD-specific Tctl parsing. Zone
    # numbering isn't guaranteed to mean the same thing across boards, so
    # just take the hottest reading across all zones as a "how hot is this
    # box running" proxy — good enough for a status bar.
    local hottest=""
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$f" ]] || continue
        local milli
        milli="$(cat "$f" 2>/dev/null)"
        [[ "$milli" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$hottest" || "$milli" -gt "$hottest" ]]; then
            hottest="$milli"
        fi
    done
    [[ -n "$hottest" ]] && awk -v m="$hottest" 'BEGIN { printf "%.1f", m/1000 }'
}

# Launches (or relaunches) xmrig from config.json + the current
# $MINE_THREADS, capturing its PID into the global $XMRIG_PID, registering
# it with gamemoded, and setting its baseline niceness. Called once below,
# and again from the control loop further down when it recovers a higher
# thread count later in the session.
launch_xmrig() {
    echo "🚀 Starting XMRig (threads=${MINE_THREADS})"
    # Backgrounded (not exec'd) so we can capture xmrig's actual PID.
    "$XMRIG_BIN" -c config.json &
    XMRIG_PID=$!

    # `gamemoderun`'s usual trick is LD_PRELOAD-ing a constructor that
    # self-registers with gamemoded — but ld.so ignores
    # LD_PRELOAD/LD_LIBRARY_PATH for any binary carrying file capabilities
    # (same class of protection as the nosuid mount stripping capabilities
    # above, just enforced by the dynamic linker instead of the kernel), so
    # it silently never fires on $XMRIG_BIN. Register directly over D-Bus
    # instead — same effect, no LD_PRELOAD involved. gamemoded's reaper
    # thread auto-unregisters it a few seconds after the process exits.
    if busctl --user call com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode RegisterGame i "$XMRIG_PID" >/dev/null 2>&1; then
        echo "   ✅ registered PID $XMRIG_PID with gamemoded"
    else
        echo "⚠️  gamemode registration failed, continuing without" >&2
    fi
}

# Single control loop, owns the xmrig process for the life of the script.
# Runs regardless of TTY.
(
    launch_xmrig

    TEMP_HIGH=85
    TEMP_OK=75
    # Cools by 10% of the hardware's freq range per tick sustained hot,
    # warms back by the same step sustained cool — small enough not to
    # overshoot and oscillate, big enough to matter within a few ticks.
    FREQ_STEP=$(( (CPUFREQ_HW_MAX - CPUFREQ_HW_MIN) / 10 ))
    CURRENT_MAX_FREQ="$CPUFREQ_HW_MAX"
    # Optimistic until proven otherwise — self-disables the first time an
    # actual write fails, rather than retrying (and re-logging) every 15s
    # for the rest of the session once we know it won't work.
    CPUFREQ_WRITABLE=true
    while kill -0 "$XMRIG_PID" 2>/dev/null; do
        TEMP="$(fetch_cpu_temp)"

        # Thermal governor: caps clock speed under whatever's currently
        # running instead of stopping threads — xmrig itself is never
        # touched (no restart, no RandomX dataset re-init), it just runs
        # cooler and a bit slower until temperature allows clocking back
        # up. Hardware safety, not a throughput optimization — the only
        # thing here that isn't full-power-by-default. A no-op wherever
        # CPUFREQ_HW_MAX is 0 (no accessible cpufreq knob on this host).
        if [[ -n "$TEMP" && "$CPUFREQ_HW_MAX" -gt 0 && "$CPUFREQ_WRITABLE" == true ]]; then
            if awk -v t="$TEMP" -v hi="$TEMP_HIGH" 'BEGIN { exit !(t >= hi) }'; then
                NEW_MAX_FREQ=$((CURRENT_MAX_FREQ - FREQ_STEP))
                [[ "$NEW_MAX_FREQ" -lt "$CPUFREQ_HW_MIN" ]] && NEW_MAX_FREQ="$CPUFREQ_HW_MIN"
                if [[ "$NEW_MAX_FREQ" -ne "$CURRENT_MAX_FREQ" ]]; then
                    if set_cpu_max_freq "$NEW_MAX_FREQ"; then
                        echo "   🌡️  ${TEMP}°C >= ${TEMP_HIGH}°C, capping max freq $((CURRENT_MAX_FREQ / 1000))MHz -> $((NEW_MAX_FREQ / 1000))MHz"
                        CURRENT_MAX_FREQ="$NEW_MAX_FREQ"
                    else
                        echo "⚠️  cpufreq write failed (permission?), disabling thermal governor for this session" >&2
                        CPUFREQ_WRITABLE=false
                    fi
                fi
            elif awk -v t="$TEMP" -v ok="$TEMP_OK" 'BEGIN { exit !(t < ok) }' && [[ "$CURRENT_MAX_FREQ" -lt "$CPUFREQ_HW_MAX" ]]; then
                NEW_MAX_FREQ=$((CURRENT_MAX_FREQ + FREQ_STEP))
                [[ "$NEW_MAX_FREQ" -gt "$CPUFREQ_HW_MAX" ]] && NEW_MAX_FREQ="$CPUFREQ_HW_MAX"
                if set_cpu_max_freq "$NEW_MAX_FREQ"; then
                    echo "   🌡️  ${TEMP}°C < ${TEMP_OK}°C, releasing max freq $((CURRENT_MAX_FREQ / 1000))MHz -> $((NEW_MAX_FREQ / 1000))MHz"
                    CURRENT_MAX_FREQ="$NEW_MAX_FREQ"
                else
                    echo "⚠️  cpufreq write failed (permission?), disabling thermal governor for this session" >&2
                    CPUFREQ_WRITABLE=false
                fi
            fi
        fi

        sleep 15
    done
) &
CONTROL_LOOP_PID=$!

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
                    DUE="$(parse_pool_field "$STATS_JSON" amtDue)"
                    PAID="$(parse_pool_field "$STATS_JSON" amtPaid)"
                    SHARES="$(parse_pool_field "$STATS_JSON" validShares)"
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
        DUE="$(parse_pool_field "$STATS_JSON" amtDue)"
        PAID="$(parse_pool_field "$STATS_JSON" amtPaid)"
        SHARES="$(parse_pool_field "$STATS_JSON" validShares)"
        awk -v due="${DUE:-0}" -v paid="${PAID:-0}" -v shares="${SHARES:-0}" 'BEGIN {
            printf "📊 XMR Pending: %.8f | XMR Paid: %.8f | Valid shares: %s\n", due/1e12, paid/1e12, shares
        }'
    else
        echo "⚠️  couldn't reach the pool's API (direct blocked, no local Tor)" >&2
    fi
fi

# Wait on the control loop, not a fixed xmrig PID — the loop restarts
# xmrig internally when it recovers threads, so the original PID could
# exit (intentionally) well before the session is actually done.
wait "$CONTROL_LOOP_PID"
