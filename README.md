# nixos-xmr-rig

Project-scoped Monero (XMR) CPU mining setup for NixOS. No system config
changes — dependencies via `nix develop`. Supports x86_64-linux and
aarch64-linux (e.g. Raspberry Pi).

## Prerequisites

- Nix with flakes enabled
- `sudo`/`doas`
- A Monero wallet address

## Setup

```sh
git clone https://github.com/hydroakri/nixos-xmr-rig
cd nixos-xmr-rig
echo "YOUR_MONERO_ADDRESS" > wallet-address.local
./mine.sh
```

`wallet-address.local` and `config.json` are gitignored. `config.json` is
generated from `config.json.example` on first run.

## What `mine.sh` does

- Resolves `xmrig` from the nix store, copies it to `/var/lib/xmr-mining`
- Injects the wallet address from `wallet-address.local` into `config.json`
- Resolves the pool IP via Quad9 unfiltered DoH (`9.9.9.10`), writes it
  into `config.json`
- Uses every physical core by default (override with `MINE_THREADS` in
  `mining-profile.local` to cap it) and pins threads to one logical CPU
  per physical core — never naive sequential 0..N-1, which would start
  doubling up on SMT sibling pairs past the physical core count; RandomX
  doesn't benefit from those and xmrig's own default avoids them too
- Picks RandomX fast/light mode from available RAM (< 3072MB → light), then
  sizes and reserves huge pages to match the mode and actual thread count —
  not a flat constant, so it doesn't over- or under-reserve on a host
  different from the one this was developed on
- Grants `cap_sys_rawio` + `cap_dac_override` on the xmrig binary (MSR mod;
  x86-only, harmlessly inert on ARM)
- Grants this user write access (`chmod a+w`; sysfs doesn't honor POSIX
  ACLs) on `cpufreq scaling_max_freq` for every logical core, not just
  the mining-pinned ones (where the driver exposes it — this box's
  `amd-pstate-epp` does) — so the thermal governor below can cap/release
  clock speed later without a sudo prompt an unattended background loop
  can't provide, then resets it to the hardware max so the loop starts
  from a known-clean full-speed state regardless of what a prior session
  left it at. Confirmed live that scoping this to only the mining-pinned
  cores (an earlier version of this script did) is actually
  counterproductive: an idle SMT sibling with no mining thread on it
  still shares the same chip's package-level boost/power arbitration,
  and leaving it uncapped gives the firmware an escape valve to shift
  boost budget there instead of respecting the cap on the core actually
  pinned for mining — verified capping only 8 of 16 cores left 7 of the
  8 mining-pinned ones running 200-600MHz above their requested cap
  under real load; capping all 16 fixed it completely.
- Force-enables xmrig's loopback HTTP API (port 18099, restricted) for the
  live hashrate reading below
- Grants this user write access on `cpufreq scaling_governor` for every
  core, same reasoning and mechanism as `scaling_max_freq` above — a
  self-started gamemoded (next bullet) needs it, since unlike a
  system-installed one it carries no capability wrapper and its governor
  switch is a plain file write
- Starts its own `gamemoded` if the session D-Bus doesn't already have one
  registered (e.g. a bare SSH-only host with no desktop session or system
  gamemode install) — left running after this script exits so later runs
  find it already there. A no-op wherever one's already running (e.g. a
  desktop's own system-wide install)
- Registers the process with `gamemoded` over D-Bus (CPU governor →
  performance, I/O priority)
- Runs `xmrig -c config.json`
- On a real terminal, reserves the last row as a live status bar via ANSI
  scroll-region control codes — no tmux dependency: CPU temp + hashrate
  (local, refreshed every 10s) and pool pending/paid/shares/ETA-to-payout
  (network, refreshed every 5 min, falling back to local Tor SOCKS on
  `127.0.0.1:9050` if present and direct access is blocked). Piped/non-TTY
  runs get a single one-line pending/paid print instead of the bar.
- Runs a control loop for the life of the process that adjusts
  `scaling_max_freq` on every logical core (not just the mining-pinned
  ones — see above, an idle core left uncapped undermines the cap on the
  cores actually mining) every 15s using proportional control (step size scales
  with the temperature error, not a fixed-threshold trigger) targeting a
  device-type-detected default (see the table below) — converges to a
  stable frequency in 1-2 ticks under sustained load instead of
  oscillating off a hard cap threshold and back. Capping
  (too hot) is twice as sensitive as releasing (cooler than target):
  overshooting down only costs a little throughput, overshooting up risks
  tripping the hardware's own PROCHOT before the next tick catches it.
  Hardware safety, not a throughput optimization, so it applies regardless
  of thread count. Doesn't touch xmrig at all (no restart, no RandomX
  dataset re-init) — just clocks down whatever's currently running. A
  no-op wherever the cpufreq grant above wasn't possible.
- If frequency capping alone reaches the hardware's floor (or is detected
  ineffective — some hardware accepts the write but a firmware-level
  power policy ignores it anyway, see below) and temperature is still
  over target, the same loop escalates to duty-cycling xmrig's own HTTP
  API `pause`/`resume` (loopback-only, token-authenticated): every tick
  alternates on/off at a percentage that scales with how far over target
  the temperature is, using the same proportional shape as the frequency
  governor above but applied to time-averaged load instead of clock
  speed. Deliberately not one long pause — a single sustained pause means
  every resume throws 100% load at a chip that was just sitting at 0%,
  spiking temperature straight back up; alternating in short (one tick)
  bursts keeps the *average* load down without ever fully stopping or
  fully maxing out. See `MINE_PAUSE_*` below.
- Force-enables xmrig's own built-in `pause-on-battery` (opt-out, not
  opt-in — see `MINE_ALLOW_BATTERY_MINING` below) so a laptop pauses
  mining the moment it's unplugged and resumes automatically once AC
  power returns — the same underlying pause/resume mechanism as the
  thermal escalation above, just triggered by power source instead of
  temperature. Native to xmrig rather than something polled from sysfs
  here, since xmrig already needs to detect this reliably for its own
  purposes.

Sudo is only invoked when state actually needs to change. Huge pages and
the capability grant persist until reboot.

Full power by default: every physical core, no OS-level deference to
other processes on the box. The only thing that ever holds it back is the
thermal governor above — hardware safety, not a courtesy setting.

## Running on a shared/constrained host

Memory sizing (RandomX mode/huge pages) is auto-detected from available
RAM. Thread count is not — it always defaults to every physical core.
On a host where something else needs the CPU (a router, an SBC running
other workloads), cap it explicitly via `mining-profile.local`
(gitignored):

```sh
MINE_THREADS=1          # cap CPU threads (default: unset = every physical core)
MINE_RANDOMX_MODE=light # force fast/light (default: unset = auto from available RAM)
MINE_HUGEPAGES=0         # override the huge-pages page count, 0 disables it (default: unset = auto)
MINE_CPU_PRIORITY=1      # xmrig's own 0-5 internal thread priority (default: unset)
MINE_TEMP_TARGET=70              # thermal governor's target °C (default: unset = device-type-detected, see below)
MINE_TEMP_DEADBAND=3             # +/-°C dead zone around the target (default: unset = device-type-detected)
MINE_PAUSE_ESCALATION_TICKS=4    # governor ticks pinned at the freq floor before duty-cycling starts (default: unset = 4, ~60s)
MINE_PAUSE_MIN_RUN_SECONDS=60    # minimum time back at full hashing before duty-cycling can trigger again (default: unset = 60)
MINE_ALLOW_BATTERY_MINING=1      # keep mining on battery power instead of auto-pausing (default: unset = pause on battery)
```

When `MINE_TEMP_TARGET`/`MINE_TEMP_DEADBAND` aren't set, `mine.sh` picks a
default from the host's detected device class instead of one flat number
— a conservative-for-sustained-operation internal-temp ceiling (CPU
Tctl/Tdie/core, not heatsink or case surface) differs a lot by how a
device is built to shed heat:

| Device class | Detected via | Sustained-safe | Short-term peak | Avoid sustained |
|---|---|---|---|---|
| SBC (e.g. Raspberry Pi) | `uname -m` is `aarch64`/`arm*` | 40–70°C | 70–80°C | above 80°C |
| Laptop | `/sys/class/power_supply/BAT*` exists | 50–85°C | 85–95°C | above 95°C, near 100°C |
| Desktop | neither of the above | 35–75°C | 75–85°C | above 85–90°C |

`mine.sh` targets the middle of each class's sustained-safe range: 65°C
±3 (SBC), 80°C ±2 (laptop), 72°C ±2 (desktop). Override explicitly if the
detected class is wrong for a given host, or to trade some throughput for
running further from the limit — lowering the target makes the governor
start capping clock speed earlier and settle at a lower steady-state
frequency.

The `MINE_PAUSE_*` knobs tune a second, last-resort escalation: on
hardware where frequency capping alone can't reach equilibrium (passive
cooling under sustained 100% load may run hotter at the floor frequency
than the heatsink can shed — or, confirmed live on one real AMD laptop
this project runs on, a firmware AC-power boost policy that accepts the
frequency-cap write but simply doesn't act on it, across every governor/
EPP combination that hardware offers), the control loop switches to
duty-cycling xmrig's pause/resume once frequency capping has run out of
room (or been shown ineffective) and temperature is still over target.

This is proportional, not a fixed on/off switch: each 15s tick computes a
target duty cycle (0-100%, the fraction of time xmrig should be hashing)
from the current temperature error — 90% right at the trigger threshold,
ramping down to a 15% floor by 10°C past it — then a small accumulator
spreads that percentage evenly across ticks (e.g. 40% duty lands roughly
as on,off,off,on,off,... not one long burst followed by one long gap).
Exits back to full-time running once temperature has stayed comfortably
under target for the same number of ticks the trigger required, keeping
entry and exit symmetric. This is pool mining over a persistent
connection (PPLNS reward, `keepalive: true`), so none of this needs any
awareness of Monero's block time — the pool pushes new jobs on its own
whenever a block appears, and reward is proportional to shares
contributed, not sensitive to when within a payout window a miner was
active. These defaults are a conservative starting point, not tuned
against real hardware yet.

## Notes

- CPU-only. GPU mining RandomX is slower and less power-efficient than CPU
  — `opencl`/`cuda` stay disabled.
- Defaults to SupportXMR over TLS, remote-node setup — no local `monerod`.
- Never touches wallet private keys, seed phrases, or view keys.
- `"autosave": false` in `config.json.example` — xmrig would otherwise
  write back per-host thread arrays on exit, baking one machine's core
  topology into a file another host then can't use.
