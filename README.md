<div align="center">

# Mac Cleaner

An agent-driven cleanup and optimization toolkit for Apple Silicon Macs that scans
disk and RAM, sorts what's reclaimable by size and risk, and runs nothing until you approve it.

![Platform](https://img.shields.io/badge/platform-Apple%20Silicon-111111)
![macOS](https://img.shields.io/badge/macOS-15%20|%2026-1f6feb)
![Shell](https://img.shields.io/badge/shell-bash%203.2-4c4c4c)
![License](https://img.shields.io/badge/license-MIT-2ea043)

</div>

## Overview

Mac Cleaner is three Bash scripts and a `CLAUDE.md` playbook that keep an Apple Silicon Mac lean.
It does three jobs, and it shows you exactly what it will do before doing it:

| Job | What it does |
|-----|--------------|
| Scan | Finds what is wasting disk space, largest first. Read-only; deletes nothing. |
| Clean | Reclaims space one approved step at a time. Dry-run by default. |
| Optimize | Trims background work, login items, and stale caches that burn RAM and CPU. Background-only. |

It is tuned for 8 GB machines, where RAM rather than disk is usually the real bottleneck, though every
command works on any M-series Mac. Disk cleanup never frees RAM, so the toolkit treats the two as separate
jobs and does not conflate them.

This is not a one-click cleaner. Nothing runs without your approval, every action is labelled by risk, and
your data is protected by design. The resting state of the toolkit is a read-only scanner: it changes nothing
until told to.

## Safety model

- Read-only first. Nothing is deleted, moved, or changed without an explicit OK.
- Transparency before every run. The toolkit states what will run, what each step does, why, and the size and
  risk, then asks whether to run everything or only some items.
- Risk tiers. Every action is labelled Safe, Review, or Caution. Caution items carry an explicit tradeoff
  warning inline.
- Largest first. Findings are sorted by size so the big wins are obvious.
- No UI or visual changes, ever. The toolkit does not touch reduced motion, animations, the Dock, the menu
  bar, or font smoothing. Optimizations only affect background work: caches, indexing, login items, and junk.
- Protected paths. `~/.claude` and anything you add to the protect list (or `--ignore`) are excluded from
  every scan, search, and clean. Photos, Mail, messaging-app data, iOS backups, and SIP-protected system
  paths are never deletion targets.

## Requirements

- An Apple Silicon Mac (M-series), macOS Sequoia (15) or Tahoe (26).
- Stock Bash (3.2) and the BSD userland. No GNU tools required.
- Optional, for richer scans: `dust`, `dua-cli`, `gdu`, `fclones` (install via Homebrew).

## Install

```bash
git clone https://github.com/pehqge/mac-cleaner.git
cd mac-cleaner
chmod +x scripts/*.sh
```

## Quick start with Claude (recommended)

The repo ships a `CLAUDE.md` playbook, and the toolkit is designed to be driven by an agent. The simplest way
to use it:

```bash
cd mac-cleaner
claude
```

Then tell Claude what you want in plain language, for example `clean my mac`. Claude reads the playbook,
runs a read-only scan, presents a report grouped by Safe / Review / Caution sorted by size, explains each item
and its tradeoff, and waits for your explicit approval before changing anything.

Useful things to say:

- `scan` — a read-only report of everything reclaimable, grouped by risk tier.
- `clean my mac` or `clean all safe` — Claude explains each item, re-prints the exact commands, and waits for
  your OK. `clean all safe` only ever runs Safe-labelled commands.
- `optimize` — background and performance tweaks (login items, Homebrew services, DNS flush, Power Nap,
  Spotlight scope). Each shows a read-only check first; nothing runs without approval.
- `free up memory` — lists the top memory consumers and helps you gracefully quit idle apps, the real speed
  lever on 8 GB.

You get [Claude Code](https://claude.com/claude-code) at claude.com/claude-code. The scripts also run on their
own without Claude, as shown below.

## Using the scripts directly

Scan (always safe, deletes nothing):

```bash
./scripts/scan.sh
```

Prints disk usage (real APFS free space, including purgeable), RAM and swap pressure, the top consumers, and a
categorized report of what is reclaimable, largest first.

Preview a clean (dry-run by default):

```bash
./scripts/clean.sh              # shows exactly what WOULD be removed, with sizes
./scripts/clean.sh --safe-only  # only the Safe tier
```

Apply a clean, after reviewing the plan:

```bash
./scripts/clean.sh --apply      # re-prints the batch, asks you to type "apply",
                                # then confirms each Review item individually
```

Audit and apply background optimizations:

```bash
./scripts/optimize.sh           # read-only audit of login items, services, Spotlight, power, swap
./scripts/optimize.sh --apply   # opt-in background tweaks, each confirmed individually
```

### `clean.sh` flags

| Flag | Effect |
|------|--------|
| _(none)_ | Dry-run preview; nothing is deleted |
| `--apply` | Delete, after a summary and typing `apply` |
| `--safe-only` | Limit to the Safe tier |
| `--include-downloads` | Also consider Downloads build artifacts (e.g. `.next`); off by default |
| `--ignore <dir>` | Protect an extra directory (repeatable) |
| `--plan-tsv` | Print the plan as `id⇥group⇥size⇥label⇥cmd` and exit; deletes nothing |
| `--apply --select 1,5` | Apply only the listed plan ids (ids come from `--plan-tsv` or the `[brackets]`) |

Every plan item carries a stable id (shown in `[brackets]`). `--plan-tsv` plus `--select` let an agent build
an interactive, per-file selection — you tick exactly which items to remove, name and size shown — then apply
only that subset. Selection happens in the agent; the script just executes the approved ids.

## Protecting extra paths

The scripts already protect `~/.claude` and adapt to what is actually on your machine. To permanently protect
extra paths (a browser profile, a password-manager vault, a working directory) without editing the scripts and
without committing anything, use a personal, git-ignored config:

```bash
cp scripts/local.config.example.sh scripts/local.config.sh
# edit scripts/local.config.sh and add your paths to PROTECT_EXTRA=(...)
```

`scripts/local.config.sh` is listed in `.gitignore`, so your settings stay on your machine. `scan.sh` and
`clean.sh` merge it automatically on every run.

## How it works

```
scan  ──▶  explain & propose  ──▶  you approve (all / a tier / specific items)  ──▶  clean  ──▶  verify
(read-only)   (transparency gate)        (dry-run unless --apply)              (before/after delta)
```

Re-run it anytime. The resting state is a scanner: emptied caches show 0 and drop off the menu, and new growth
(regrown package stores, future iOS backups, Time Machine snapshots) is surfaced automatically.

### What it looks at

Safe (regenerable caches and junk): pnpm store, npx cache, Homebrew stale downloads and old versions, uv
cache, GoogleUpdater CRX cache, unavailable Xcode simulator runtimes, other tool caches found by the scan,
DNS flush.

Review (verify before deleting): per-app user caches (each picked individually), corrupt preference plists,
stale third-party logs over 30 days old, Next.js build caches, duplicate or non-default Rust toolchains,
unused Docker data, Cargo registry caches, old Downloads archives and installers, inactive `node_modules`,
and a login-item (including broken/orphaned ones) and Homebrew-service audit.

Caution (data loss or rebuild cost): an active virtualenv your `python3` lives in (blocked by default),
`sleepimage` and hibernation, local APFS snapshots, iOS device backups, and user data (Photos, messaging apps,
Mail), which is never a deletion target.

RAM is freed only by quitting idle apps and trimming login items, never by disk cleanup. The toolkit keeps
those as separate, clearly labelled jobs.

## Repository layout

```
mac-cleaner/
├── CLAUDE.md                  # agent playbook: the full scan → approve → clean → verify workflow and rules
├── README.md                  # this file
├── scripts/
│   ├── scan.sh                # read-only deep scan
│   ├── clean.sh               # dry-run-default cleanup (Safe/Review tiers, per-item confirm)
│   ├── optimize.sh            # read-only audit and opt-in background/perf tweaks
│   └── local.config.example.sh # template for your personal, git-ignored protect list
└── references/
    ├── macos-optimization.md  # RAM and background-perf guide (8 GB Apple Silicon explainer)
    └── safety-do-not-delete.md # the do-not-delete list, macOS protections, preserved-paths policy
```

## Acknowledgements

Thanks to Carlos Eduardo ([@carloslibardo](https://github.com/carloslibardo)) for the original toolkit this
project grew from, [carloslibardo/agent-toolkit](https://github.com/carloslibardo/agent-toolkit). This repo is
an expanded, re-researched, and hardened evolution of that work.

## License

[MIT](LICENSE) © Pedro Gimenez

## Disclaimer

This toolkit is conservative by design and asks before doing anything destructive, but you are responsible for
reviewing each action. Read the plan, keep backups of anything irreplaceable, and when in doubt, do not delete.
