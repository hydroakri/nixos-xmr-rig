# nixos-xmr-rig

Project-scoped Monero (XMR) CPU mining setup for NixOS. No system config
changes — dependencies come from a local flake dev shell via plain `nix
develop` (no direnv, no `.envrc`, no global `nix profile install`).

## Prerequisites

- NixOS (or any system with Nix + flakes enabled)
- `sudo`/`doas` for one-time huge pages + MSR capability setup
- A Monero wallet address to receive payouts (this repo never touches
  wallet keys or seeds — bring your own address)

## Setup

```sh
git clone https://github.com/hydroakri/nixos-xmr-rig
cd nixos-xmr-rig
echo "YOUR_MONERO_ADDRESS" > wallet-address.local
./mine.sh
```

**`wallet-address.local` must exist before the first run** — it's a
one-line file with your Monero payout address, deliberately gitignored so
your real address never ends up in this repo's history. `mine.sh` reads it
and injects it into a local `config.json` (also gitignored, generated from
`config.json.example` on first run) at every launch.

## What `mine.sh` does, on every run

- Resolves the `xmrig` binary path from the nix store (`nix develop`)
- Copies it to `/var/lib/xmr-mining` — **not** inside the project dir,
  because `/home` on this machine (and often elsewhere) is mounted
  `nosuid`, which silently strips file capabilities on exec. `/var/lib`
  sits on the root filesystem instead.
- Injects your wallet address from `wallet-address.local` into
  `config.json`
- Resolves the mining pool's current IP via Quad9's **unfiltered** DoH
  endpoint (`9.9.9.10`) and rewrites it into `config.json` — works around
  DNS-level blocklists (many privacy/security DNS setups, and even Quad9's
  own default filtered resolver, flag known mining pool domains)
- Reserves enough huge pages for the full RandomX dataset (2GB+) plus
  per-thread scratchpads — skipped if already reserved
- Grants `cap_sys_rawio` + `cap_dac_override` on the xmrig binary so it can
  apply the Ryzen MSR performance mod without running as root — skipped if
  already granted. `cap_dac_override` is a broad capability (bypasses file
  permission checks generally, not just for the MSR device); it's scoped
  to this one binary via file capabilities, but worth knowing if you're
  auditing this for a hardened setup.
- Starts XMRig under `gamemoderun` (CPU governor → performance)

Sudo/doas is only invoked when something actually needs to change — huge
pages and the capability grant both persist until reboot (or until the
binary changes, for the capability), so repeat "start mining" runs after
the first one need no password at all.

## Notes

- CPU-only. RandomX (Monero's PoW algorithm) is deliberately designed to
  resist GPU/ASIC advantage — GPU mining it is typically slower *and* less
  power-efficient than a decent CPU, so `opencl`/`cuda` stay disabled in
  `config.json.example`.
- Defaults to a public pool (SupportXMR) over TLS with a remote node setup
  in mind — no local `monerod` required.
- This repo intentionally never reads, writes, or displays wallet private
  keys, seed phrases, or view keys. Wallet creation and backup is entirely
  out of scope — use whatever Monero wallet you like.
