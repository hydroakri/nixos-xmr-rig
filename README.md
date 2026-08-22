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
- Picks a thread count from current load average (physical cores minus
  ceil(load1), floor of 1) and pins it to one logical CPU per physical
  core — never naive sequential 0..N-1, which would start doubling up on
  SMT sibling pairs past the physical core count; RandomX doesn't benefit
  from those and xmrig's own default avoids them too
- Picks RandomX fast/light mode from available RAM (< 3072MB → light), then
  sizes and reserves huge pages to match the mode and actual thread count —
  not a flat constant, so it doesn't over- or under-reserve on a host
  different from the one this was developed on
- Grants `cap_sys_rawio` + `cap_dac_override` on the xmrig binary (MSR mod;
  x86-only, harmlessly inert on ARM)
- Grants this user write access (`chmod a+w`; sysfs doesn't honor POSIX
  ACLs) on `cpufreq scaling_max_freq` for every core (where the driver
  exposes it — this box's `amd-pstate-epp` does), so the thermal governor
  below can cap/release clock speed later without a sudo prompt an
  unattended background loop can't provide, then resets it to the
  hardware max so the loop starts from a known-clean full-speed state
  regardless of what a prior session left it at
- Force-enables xmrig's loopback HTTP API (port 18099, restricted) for the
  live hashrate reading below
- Registers the process with `gamemoded` over D-Bus (CPU governor →
  performance, I/O priority)
- Runs `xmrig -c config.json`
- On a real terminal, reserves the last row as a live status bar via ANSI
  scroll-region control codes — no tmux dependency: CPU temp + hashrate
  (local, refreshed every 10s) and pool pending/paid/shares/ETA-to-payout
  (network, refreshed every 5 min, falling back to local Tor SOCKS on
  `127.0.0.1:9050` if present and direct access is blocked). Piped/non-TTY
  runs get a single one-line pending/paid print instead of the bar.
- Runs a control loop for the life of the process (owns xmrig's PID,
  restarts included) that rechecks load average every 15s and renices
  xmrig between a baseline and 19 in response (hysteresis: raises at
  other-load>0.5, only lowers back at <0.1, so it doesn't flip-flop when
  load hovers near the line) — this is what keeps deferring to other work
  if the box gets busier hours into a session (e.g. a router's traffic
  spiking). The baseline comes from `MINE_CPU_PRIORITY` if set (0→nice 19,
  5→nice 0) — a floor for how eager xmrig gets to be *when nothing's
  contending*, not a way to opt out of deferring when something actually
  is.
- If the thread count came from auto-detection (not an explicit
  `MINE_THREADS`) and load stays low enough to fit more threads for 20
  straight minutes, the same loop restarts xmrig with a recomputed
  (higher) thread count — the launch-time pick only reacts to load *then*,
  this is what lets it recover back up once a lull passes rather than
  staying capped for the rest of the session. Huge pages are provisioned
  for all physical cores up front specifically so this restart never needs
  a bigger reservation — and therefore never needs a sudo prompt — mid
  session. Doesn't apply when `MINE_THREADS` is explicit: that's a
  deliberate cap (e.g. a router you never want fully loaded), not a
  starting guess to grow back from.
- The same loop caps `scaling_max_freq` on every core by 10% of the
  hardware's range whenever CPU temp is >= 85°C, and releases it back by
  the same step once temp drops under 75°C — a hardware-safety response,
  not a throughput one, so unlike thread count it applies even with an
  explicit `MINE_THREADS`. Doesn't touch xmrig at all (no restart, no
  RandomX dataset re-init) — just clocks down whatever's currently
  running. A no-op wherever the cpufreq ACL grant above wasn't possible.

Sudo is only invoked when state actually needs to change. Huge pages and
the capability grant persist until reboot.

## Running on a shared/constrained host

Both memory (RandomX mode/huge pages) and CPU contention (thread count,
ongoing renice) are already auto-detected — no config needed for most
cases, including a router/SBC also running other important workloads.
`mining-profile.local` (gitignored) exists for when you want to override
the auto-detection instead of trusting it:

```sh
MINE_THREADS=1          # cap CPU threads (default: unset = auto from load average)
MINE_RANDOMX_MODE=light # force fast/light (default: unset = auto from available RAM)
MINE_HUGEPAGES=0         # override the huge-pages page count, 0 disables it (default: unset = auto)
MINE_CPU_PRIORITY=1      # xmrig's own 0-5 internal thread priority (default: unset)
```

## Notes

- CPU-only. GPU mining RandomX is slower and less power-efficient than CPU
  — `opencl`/`cuda` stay disabled.
- Defaults to SupportXMR over TLS, remote-node setup — no local `monerod`.
- Never touches wallet private keys, seed phrases, or view keys.
- `"autosave": false` in `config.json.example` — xmrig would otherwise
  write back per-host thread arrays on exit, baking one machine's core
  topology into a file another host then can't use.
