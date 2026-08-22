# nixos-xmr-rig

Project-scoped Monero (XMR) CPU mining setup for NixOS. No system config
changes — dependencies via `nix develop`.

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
- Reserves huge pages (1280 × 2MB) for the RandomX dataset + thread
  scratchpads
- Grants `cap_sys_rawio` + `cap_dac_override` on the xmrig binary (MSR mod)
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

Sudo is only invoked when state actually needs to change. Huge pages and
the capability grant persist until reboot.

## Notes

- CPU-only. GPU mining RandomX is slower and less power-efficient than CPU
  — `opencl`/`cuda` stay disabled.
- Defaults to SupportXMR over TLS, remote-node setup — no local `monerod`.
- Never touches wallet private keys, seed phrases, or view keys.
