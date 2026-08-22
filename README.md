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
- Runs a control loop for the life of the process that adjusts
  `scaling_max_freq` on every core every 15s using proportional control
  (step size scales with the temperature error, not a fixed-threshold
  trigger) targeting 80°C ±2°C — converges to a stable frequency in 1-2
  ticks under sustained load instead of oscillating off a hard cap
  threshold and back. Capping (too hot) is twice as sensitive as releasing
  (cooler than target): overshooting down only costs a little throughput,
  overshooting up risks tripping the hardware's own PROCHOT before the
  next tick catches it. Hardware safety, not a throughput optimization, so
  it applies regardless of thread count. Doesn't touch xmrig at all (no
  restart, no RandomX dataset re-init) — just clocks down whatever's
  currently running. A no-op wherever the cpufreq grant above wasn't
  possible.

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
```

## Notes

- CPU-only. GPU mining RandomX is slower and less power-efficient than CPU
  — `opencl`/`cuda` stay disabled.
- Defaults to SupportXMR over TLS, remote-node setup — no local `monerod`.
- Never touches wallet private keys, seed phrases, or view keys.
- `"autosave": false` in `config.json.example` — xmrig would otherwise
  write back per-host thread arrays on exit, baking one machine's core
  topology into a file another host then can't use.
