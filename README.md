<div align="center">

# 🧹 Mac Cleaner

**A safe, agent-driven macOS cleanup & optimization toolkit for Apple Silicon.**

Reclaim disk space, relieve RAM pressure, and trim background work —
without ever risking your data or changing how your Mac looks and feels.

`read-only by default` · `summary before every action` · `zero data loss` · `no UI changes`

</div>

---

## What it is

Mac Cleaner is a small toolkit (three Bash scripts + an agent playbook) that keeps an Apple Silicon Mac
**lean and fast**. It does three jobs, and it always shows you exactly what it will do **before** it does it:

| Job | What it does |
|-----|--------------|
| 🔍 **Scan** | Find what's actually wasting disk space — largest first. Read-only; deletes nothing. |
| 🧽 **Clean** | Reclaim space safely, one approved step at a time. Dry-run by default. |
| ⚡ **Optimize** | Trim background work, login items, and stale caches that burn RAM/CPU. **Background-only.** |

It's tuned for **8 GB machines**, where RAM — not disk — is usually the real bottleneck, but every command
works on any M-series Mac. No amount of disk cleanup frees RAM; the toolkit treats those as separate jobs and
never conflates them.

This is **not** a generic "one-click cleaner" app. Nothing runs without your explicit approval, every action
is labeled by risk, and your important data is protected by design.

---

## Why it's safe

- **🔒 Read-only first.** Nothing is deleted, moved, or changed without your explicit OK.
- **📋 Transparency before every run.** It tells you *what* will run, *what each step does*, *why*, and the
  *size/risk* — then asks whether to run everything or just some items.
- **🗂️ Zero data loss.** Every action is labeled **Safe / Review / Caution**, and Caution items carry an
  explicit tradeoff warning.
- **📏 Largest first.** Findings are sorted by size so the big wins are obvious.
- **🎨 No UI or visual changes — ever.** No reduced motion, no disabled animations, no Dock/menu-bar tweaks,
  no font-smoothing changes. Optimizations only touch *background* work: caches, indexing, login items, junk.
- **🛡️ Protected paths.** `~/.claude` and any path you add to the protect list (or `--ignore`) are excluded
  from every scan, search, and clean. Photos, Mail, messaging-app data, iOS backups, and SIP-protected system
  paths are never deletion targets.

---

## Getting started

### Requirements
- An Apple Silicon Mac (M-series), macOS Sequoia (15) or Tahoe (26).
- Stock Bash (3.2) + BSD userland — no GNU tools required. (Optional richer scans: `dust`, `dua-cli`, `gdu`,
  `fclones` via Homebrew.)

### 1. Get the repo
```bash
git clone https://github.com/pehqge/mac-cleaner.git
cd mac-cleaner
chmod +x scripts/*.sh
```

### 2. Scan (always safe — deletes nothing)
```bash
./scripts/scan.sh
```
Prints disk usage (real APFS free space), RAM/swap pressure, top consumers, and a categorized report of what's
reclaimable, largest first.

### 3. Preview a clean (dry-run by default)
```bash
./scripts/clean.sh              # shows exactly what WOULD be removed, with sizes
./scripts/clean.sh --safe-only  # only the Safe tier
```

### 4. Apply a clean (after reviewing the plan)
```bash
./scripts/clean.sh --apply      # re-prints the batch, asks you to type "apply",
                                # then confirms each Review item individually
```

### 5. Audit & apply background optimizations
```bash
./scripts/optimize.sh           # read-only audit of login items, services, Spotlight, power, swap
./scripts/optimize.sh --apply   # opt-in background tweaks, each confirmed individually
```

### Useful flags (`clean.sh`)
| Flag | Effect |
|------|--------|
| _(none)_ | Dry-run preview — nothing is deleted |
| `--apply` | Actually delete, after a summary + typing `apply` |
| `--safe-only` | Limit to the Safe tier |
| `--include-downloads` | Also consider Downloads build artifacts (e.g. `.next`) — off by default |
| `--ignore <dir>` | Protect an extra directory (repeatable) |

### Make it yours (optional)

The scripts already protect `~/.claude` and adapt to whatever is actually on your machine. To permanently
protect extra paths (a browser profile, a password-manager vault, a working dir) without editing the scripts —
and **without** that ever being committed — drop them in a personal, git-ignored config:

```bash
cp scripts/local.config.example.sh scripts/local.config.sh
# edit scripts/local.config.sh — add your paths to PROTECT_EXTRA=(...)
```

`scripts/local.config.sh` is in `.gitignore`, so your personal settings stay on your machine and never get
published. `scan.sh` and `clean.sh` merge it automatically on every run.

---

## Using it with Claude Code (recommended)

The repo ships a `CLAUDE.md` playbook. Open [Claude Code](https://claude.com/claude-code) in this directory
and just say what you want:

- **“scan”** → read-only report of everything reclaimable, grouped Safe / Review / Caution.
- **“clean”** / **“clean all safe”** → Claude explains each item, then re-prints the exact commands and waits
  for your explicit OK. “clean all safe” only ever runs Safe-labeled commands.
- **“optimize”** → background/perf tweaks (login items, Homebrew services, DNS flush, Power Nap, Spotlight
  scope). Each shows a read-only check first; nothing runs without approval.
- **“free up memory” / “ram”** → lists top memory consumers and helps you gracefully quit idle apps — the real
  speed lever on 8 GB.

The scripts also run perfectly well on their own without Claude.

---

## How it works

```
scan  ──▶  explain & propose  ──▶  you approve (all / a tier / specific items)  ──▶  clean  ──▶  verify
(read-only)   (transparency gate)        (dry-run unless --apply)              (before/after delta)
```

Re-run it anytime. The resting state is a **scanner**: emptied caches show 0 and drop off the menu, and new
growth (regrown package stores, future iOS backups, Time Machine snapshots) is surfaced automatically.

### What it looks at

**Safe — regenerable caches & junk:** pnpm store, npx cache, Homebrew stale downloads/old versions, uv cache,
GoogleUpdater CRX cache, other tool caches found by the scan, DNS flush.

**Review — verify before deleting:** Next.js build caches, duplicate/non-default Rust toolchains, unused Docker
data, Cargo registry caches, old Downloads archives/installers, inactive `node_modules`, login-item & Homebrew
service audit.

**Caution — data loss or rebuild cost:** an active virtualenv your `python3` lives in (blocked by default),
`sleepimage`/hibernation, local APFS snapshots, iOS device backups, and pure user data (Photos, messaging
apps, Mail) which is **never** a deletion target.

> RAM is freed only by quitting idle apps and trimming login items — never by disk cleanup. The toolkit keeps
> these as separate, clearly-labeled jobs.

---

## Repository layout

```
mac-cleaner/
├── CLAUDE.md                          # agent playbook: the full scan→approve→clean→verify workflow + rules
├── README.md                          # this file
├── scripts/
│   ├── scan.sh                        # read-only deep scan
│   ├── clean.sh                       # dry-run-default cleanup (Safe/Review tiers, per-item confirm)
│   └── optimize.sh                    # read-only audit + opt-in background/perf tweaks
└── references/
    ├── macos-optimization.md          # RAM + background-perf guide (8 GB Apple Silicon explainer)
    └── safety-do-not-delete.md        # the DO-NOT-DELETE list, macOS protections, preserved-paths policy
```

---

## Acknowledgements

Huge thanks to **Carlos Eduardo** ([@carloslibardo](https://github.com/carloslibardo)) for the original
toolkit this project grew from — [**carloslibardo/agent-toolkit**](https://github.com/carloslibardo/agent-toolkit).
He built and shared the first version and the approach behind it; this repo is an expanded, re-researched, and
hardened evolution of that work. 🙏

---

## License

[MIT](LICENSE) © Pedro Gimenez

## Disclaimer

This toolkit is conservative by design and asks before doing anything destructive — but you are responsible for
reviewing each action. Read the plan, keep backups of anything irreplaceable, and when in doubt, don't delete.

<div align="center">
<sub>Built for people who like their Mac fast <em>and</em> exactly the way it looks.</sub>
</div>
