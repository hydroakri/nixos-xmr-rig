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
  ACLs) on `cpufreq scaling_max_freq` for the mining-pinned cores only —
  the same subset `MINE_THREADS` pins threads to, not every core (where
  the driver exposes it — this box's `amd-pstate-epp` does) — so the
  thermal governor below can cap/release clock speed later without a sudo
  prompt an unattended background loop can't provide, then resets it to
  the hardware max so the loop starts from a known-clean full-speed state
  regardless of what a prior session left it at
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
  `scaling_max_freq` on the mining-pinned cores (same subset as the thread
  pin, not every core — one thermal sensor drives the reading, but only
  those cores are generating the heat, so a host running fewer mining
  threads than physical cores doesn't needlessly cap the other cores'
  unrelated work) every 15s using proportional control (step size scales
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
- If frequency capping alone reaches the hardware's floor and temperature
  is still over target, the same loop escalates to pausing xmrig outright
  via its own HTTP API (`json_rpc` `pause`/`resume`, loopback-only,
  token-authenticated) until it cools back down — the last resort for
  hardware (e.g. passive cooling) where no sustainable-forever frequency
  actually stays cool enough. Purely temperature-driven, not a fixed
  timer; see `MINE_PAUSE_*` below.
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
MINE_PAUSE_ESCALATION_TICKS=4    # governor ticks pinned at the freq floor before pausing (default: unset = 4, ~60s)
MINE_PAUSE_MIN_SECONDS=60        # starting minimum pause duration, adapts from here (default: unset = 60)
MINE_PAUSE_MIN_RUN_SECONDS=60    # minimum time back at full hashing before pausing again (default: unset = 60)
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
than the heatsink can shed), the control loop pauses xmrig outright via
its own HTTP API once frequency capping has run out of room and
temperature is still over target, then resumes once it's cooled back
down — temperature-driven, not a fixed timer. This is pool mining over a
persistent connection (PPLNS reward, `keepalive: true`), so pause timing
has no relationship to Monero's block time — the pool pushes new jobs on
its own whenever a block appears, and reward is proportional to shares
contributed, not sensitive to when within a payout window a miner was
active. These defaults are a conservative starting point, not tuned
against real hardware yet.

The minimum pause duration (`MINE_PAUSE_MIN_SECONDS`) is a starting
point, not a fixed constant — it adapts at runtime the same way the old
fixed-threshold frequency governor couldn't (that's what proportional
control fixed there, but pause/resume has no continuous dial to step,
only on/off, so the fix takes a different shape here). If a pause
resumes and then overheats again within roughly 2x
`MINE_PAUSE_MIN_RUN_SECONDS`, that pause clearly wasn't long enough — the
next one's minimum doubles, capped at 8x the starting value. If a pause
satisfies the resume condition in under half the current minimum, that
minimum is more conservative than this host needs — it halves back down,
floored at the starting value. A host settles at whatever duration
actually works instead of retrying the same guess indefinitely.

## Notes

- CPU-only. GPU mining RandomX is slower and less power-efficient than CPU
  — `opencl`/`cuda` stay disabled.
- Defaults to SupportXMR over TLS, remote-node setup — no local `monerod`.
- Never touches wallet private keys, seed phrases, or view keys.
- `"autosave": false` in `config.json.example` — xmrig would otherwise
  write back per-host thread arrays on exit, baking one machine's core
  topology into a file another host then can't use.
