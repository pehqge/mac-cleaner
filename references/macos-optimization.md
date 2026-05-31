# macOS Optimization & RAM Guide

Deep reference for the **background / performance** optimizations and RAM techniques used by this toolkit,
written for Apple Silicon Macs (M-series) and tuned for RAM-constrained (8 GB) machines.

> **Golden rule, repeated everywhere in this doc:** NOTHING here changes the UI, animations, or how the Mac
> looks and feels. No "reduce motion", no disabling animations, no Dock autohide/transparency/menubar tweaks,
> no font-smoothing changes. Every technique targets **background work, caches, indexing, login items, and
> junk** only. These optimizations are invisible.

> **Summary-first, dry-run-default, explicit approval.** Every state-changing command below is shown with a
> read-only **check** first. The **action** runs only after you review the check output and explicitly approve.
> Default behavior is read-only. Read-only commands are safe to run anytime.

---

## 1. The 8GB-RAM-on-Apple-Silicon explainer

On a 8 GB Apple Silicon Mac, **RAM is usually the real bottleneck, not disk.** Understand this before touching
anything:

- **Unified memory.** The 8 GB is shared by CPU, GPU, and Neural Engine. There is no separate VRAM — a
  GPU-heavy or ML workload eats into the same 8 GB your apps use.
- **Page size is 16384 bytes (16 KiB), not 4 KiB.** When reading `vm_stat`, multiply page counts by **16384**
  to get bytes. (Intel Macs used 4096; do not reuse that number here.)
- **The memory compressor.** macOS compresses inactive pages (~50% ratio on Apple Silicon) before it swaps. A
  large "compressed" figure is normal and is *cheaper* than swap. The kernel already does this aggressively —
  no third-party app improves on it.
- **Swap lives in a hidden APFS VM volume**, not a classic pagefile. You reduce swap by reducing RAM demand
  (quit apps), **never** by disabling the dynamic pager.
- **"Memory pressure" is the metric that matters**, not "memory used". A machine can be 7.5 GB "used" and still
  green if most of that is reclaimable file cache. It is *red* when the compressor and swap are saturated.
- **When you see near-full swap** (e.g. `vm.swapusage` showing used ≈ total) you are in genuine **red-zone**
  pressure. The only durable fix is **quitting idle Electron/Chromium apps and trimming login items** — no disk
  cleanup frees a single byte of RAM.

### What does NOT help RAM (and why)
- **`sudo purge`** — frees only a few hundred MB of inactive/file-cache pages, and those pages existed to speed
  re-reads; it causes a brief I/O slowdown as caches re-warm. It does **not** free swap or close apps. Marginal
  value; never schedule it.
- **Third-party "memory cleaner" apps** — they wrap `sudo purge` in a GUI and add their own LaunchAgents that
  *raise* idle CPU. Net negative.
- **Disabling swap on 8 GB** — guaranteed bad. Disabling the pager causes OOM process kills under pressure.

---

## 2. RAM techniques

### 2.1 Read memory pressure correctly (diagnostic — always safe)
**Benefit:** distinguishes a healthy "used but green" state from real red-zone swap thrashing.
**Risk:** safe — read-only. **Reversible:** N/A (read-only). **UI impact:** none.

```bash
# Check (read-only):
memory_pressure
sysctl vm.swapusage
vm_stat
```

Notes:
- Multiply `vm_stat` page counts by **16384** for bytes (16 KiB page).
- Apple's `vm_stat` man page has **swapins/swapouts reversed** — trust Activity Monitor or the larger value.
- A near-full `vm.swapusage` means real pressure; act via app-quit below.

### 2.2 Quit idle Electron/Chromium/heavy apps (the ONLY durable RAM fix)
**Benefit:** frees 500MB-3GB depending on the app; directly relieves near-full swap. The single
highest-impact speed action on an 8 GB machine.
**Risk:** safe — closes apps *you* choose. **Reversible:** yes (relaunch the app). **UI impact:** none.

```bash
# Check (read-only) — identify the top memory consumers:
top -o mem -l 1 -n 20
ps aux -m | head -20
```

Then, as a **separate, explicitly-approved step**, quit a *named* app gracefully (save your work first):

```bash
# Action (per-app, approved, named explicitly — NEVER chained onto the diagnostic line):
osascript -e 'quit app "AppName"'      # substitute the real app name
```

Critical safety notes:
- **Never bundle the quit onto the end of a read-only diagnostic line.** A `top ...; ps ...; osascript -e
  'quit app "X"'` one-liner is rejected: the diagnostics are read-only but the chained `quit` is a
  state-changing action. Run diagnostics first, present candidates, get approval, then quit one named app per
  approved step.
- Prefer **graceful** `osascript -e 'quit app "X"'`. Some apps quit without prompting to save — warn first.
- `kill <PID>` only if graceful quit fails; `kill -9` only as a last resort.
- **NEVER kill** `kernel_task` (the thermal governor), `WindowServer`, or `loginwindow`.
- Use BSD memory sort `ps aux -m` — GNU `--sort` does not exist on macOS.
- The usual heavy processes are browsers, chat apps (Electron), note/editor apps, music players, and multiple
  long-running agent/CLI processes. Identify them from the live `ps`/`top` output rather than assuming.

### 2.3 Reduce baseline: trim login items + background agents (most durable baseline win)
**Benefit:** cuts steady-state RAM by hundreds of MB cumulatively and reduces post-login CPU.
**Risk:** review — verify each agent before disabling. **Reversible:** yes. **UI impact:** none.

```bash
# Check (read-only inventory — run as its OWN step, do not chain into a mutating command):
sudo sfltool dumpbtm                         # full Background Task Management DB
launchctl list | grep -v com.apple | sort    # non-Apple loaded jobs
ls -la ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null
```

Before disabling a specific agent, confirm exactly what it is:

```bash
# Confirm the label (read-only):
launchctl print gui/$(id -u)/<com.vendor.agent>
```

Then disable it as a **separate approved action**:

```bash
# Action (one reviewed USER agent at a time):
launchctl bootout gui/$(id -u)/<com.vendor.agent>
# OR remove it via: System Settings > General > Login Items & Extensions
```

Critical safety notes:
- **Do not chain** `sfltool dumpbtm; launchctl list ...; launchctl bootout ...` on one line — that rides a
  mutating `bootout` along with read-only diagnostics. Separate the inventory (review) step from the single
  approved `bootout`.
- **Never `bootout` a `com.apple.*` label** — can degrade the session until logout/login.
- Use `bootout`/`bootstrap` (not the deprecated `launchctl load`/`unload`) on Apple Silicon, always with an
  explicit domain: `gui/$(id -u)/<label>` for user agents, `system/<label>` for daemons.
- **Good removal candidates:** diagnostic-only helpers, updater agents, and helpers for apps you only use
  in-browser. **Keep anything you actively rely on** (key remapper, clipboard manager, etc.). Review the live
  inventory and decide per-item — never bulk-disable.

### 2.4 `sudo purge` — low value, opt-in only
**Benefit:** frees a few hundred MB of inactive/file-cache pages; only marginally useful right after a heavy
ML/Neural-Engine workload.
**Risk:** review — net-neutral to slightly negative for general use (re-warming caches briefly slows I/O).
**Reversible:** N/A. **UI impact:** none.

```bash
# Action (one-shot, opt-in, needs sudo tty):
sudo purge
```

Notes: the compressor already manages inactive pages. Real swap relief comes from quitting apps, not purge.
**Do NOT schedule it.**

### 2.5 Never disable swap (caution — do not do this)
Keep the dynamic pager on. Disabling it causes OOM kills on an 8 GB machine under pressure. Diagnostic only:

```bash
sysctl vm.swapusage
```

---

## 3. Background / performance optimizations

All optimizations are **reversible**, **affect_ui: false**, and shown check-first / action-on-approval.

### 3.1 Audit the full Background-Task-Management (BTM) database
**Benefit:** the most complete view of every LaunchAgent/Daemon/login-item/XPC helper, including orphans from
uninstalled apps. Foundation for trimming login-time RAM/CPU.
**Risk:** safe (dump is read-only). **Reversible:** yes. **UI impact:** none.

```bash
# Check (read-only):
sudo sfltool dumpbtm
```
```bash
# Action (disable a reviewed user agent — confirm the label first, see 2.3):
launchctl bootout gui/$(id -u)/<label>      # or System Settings > Login Items & Extensions
```
> **NEVER** run `sfltool resetbtm` — it is nuclear (wipes ALL third-party background registrations and forces
> a restart).

### 3.2 Remove unneeded login items
**Benefit:** frees background RAM/CPU at every login. **Risk:** review. **Reversible:** yes. **UI impact:** none.

```bash
# Check (read-only):
launchctl list | grep -v com.apple | sort
```
```bash
# Action:
# System Settings > General > Login Items & Extensions (remove), OR:
launchctl bootout gui/$(id -u)/<label>
```
Candidates: diagnostic-only agents and helpers for apps you only use in-browser. Keep active tools you rely on.

### 3.3 Stop any auto-starting Homebrew services
**Benefit:** saves 50-300MB RAM per heavy service (postgres/redis/etc.) and avoids periodic CPU wakes.
**Risk:** review. **Reversible:** yes (`brew services start <name>`). **UI impact:** none.

```bash
# Check (read-only):
brew services list
```
```bash
# Action (stop FIRST, confirm not needed by an active workflow, then cleanup):
brew services stop <name>
brew services cleanup        # only removes plists for ALREADY-uninstalled services
```
A re-run flags any service that starts auto-starting later.

### 3.4 Power assertions audit + reduce spurious wakes
**Benefit:** fewer dark-wake events, better battery, no perf cost. **Risk:** review. **Reversible:** yes (set
values back to 1). **UI impact:** none.

```bash
# Check (read-only):
pmset -g
pmset -g assertions      # shows what is currently preventing sleep
```
```bash
# Action (disables iCloud proximity wake + Power Nap background fetch — both background-only):
sudo pmset -a proximitywake 0
sudo pmset -a powernap 0
```
Notes:
- Tradeoff: Power Nap off means Mail/Notes/Photos won't sync while the lid is closed. Reverse with
  `sudo pmset -a powernap 1` / `proximitywake 1`.
- `-a` = all power sources; use `-c` for AC-only.
- **Do NOT use `pmset lowpowermode 1`** — it throttles P-cores and affects the interactive feel. Excluded by
  policy.
- **Leave `hibernatemode` at 3** by default (safe sleep). See the sleepimage caution in
  `safety-do-not-delete.md`.

### 3.5 Spotlight indexing health check + scope heavy dev dirs
**Benefit:** prevents `mds`/`mds_stores` from saturating E-cores and SSD bandwidth during reindex. Excluding
`node_modules`/build dirs is the highest-leverage *permanent* fix for a dev machine. **Risk:** safe (status is
read-only; see warning on `-E`). **Reversible:** yes. **UI impact:** none.

```bash
# Check (read-only — status only):
sudo mdutil -s /
sudo mdutil -s /System/Volumes/Data
```
```bash
# Action (preferred — non-destructive):
#   - Add heavy dirs in System Settings > Spotlight > Search Privacy
#     (e.g. node_modules, build, .next, target dirs), OR
#   - Rename a folder to end in ".noindex"
```
Warnings:
- `mdutil -E /System/Volumes/Data` **ERASES and rebuilds the entire data-volume index** → a sustained
  CPU/RAM/SSD-I/O storm on an 8 GB machine, exactly the opposite of "make it fast", and temporarily breaks
  search. Reserve as a **last resort** (e.g. `mds` stuck >2h), with explicit approval and a "this will hammer
  the machine for a while" warning. Prefer the Privacy/`.noindex` options first.
- On recent macOS, `mdutil -s /` reporting the **signed system volume (`/`) index as read-only is NORMAL**, not
  an error. Index the **Data** volume, not `/`.
- **Do NOT** `mdutil -a -i off` — unreliable on the Data volume and breaks search.
- Scan first, never assume CoreSpotlight metadata is bloated — measure it.

### 3.6 Flush DNS cache
**Benefit:** eliminates network latency from stale resolver entries (correctness/perf). **Risk:** safe
(transient resolver state only). **Reversible:** N/A (rebuilds automatically). **UI impact:** none.

```bash
# Action (both commands required; needs sudo tty; no success output is normal):
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```
Idempotent. Briefly interrupts in-flight DNS resolution only.

### 3.7 Rebuild font caches — SYMPTOM-DRIVEN ONLY
**Benefit:** clears corrupt/oversized `fontd`/`ATSServer` caches that cause login CPU spikes. **Risk:** safe to
files (font files untouched) but disruptive. **Reversible:** caches regenerate. **UI impact:** none (does not
change how fonts look).

```bash
# Check (read-only — only run the action if fontd/ATSServer is actually spiking CPU):
top -l 2 -s 1 -stats command,cpu | grep -iE 'fontd|ATSServer'
```
```bash
# Action (ONLY when there's a real font/CPU problem — quit ALL apps first, then reboot after):
sudo atsutil databases -remove && atsutil server -shutdown
# then reboot
```
Warning: this deletes the font registration DBs and kills the font server — running apps can lose font
rendering until reboot. **Do NOT include in routine "make it fast" passes.** Gate behind explicit approval;
reboot immediately after.

### 3.8 Rebuild LaunchServices DB — SYMPTOM-DRIVEN ONLY
**Benefit:** fixes duplicate/stale "Open With" entries and stale UTI associations. **Risk:** no file data loss
but disruptive (re-scans every app bundle). **Reversible:** rebuilds. **UI impact:** none (quality-of-life only).

```bash
# Symptom check: duplicate apps in the right-click "Open With" menu.
```
```bash
# Action (ONLY when that symptom is present):
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
```
Warning: on an 8 GB Mac this triggers a full re-scan of every app across all domains — a CPU/IO spike — and
file associations can be briefly wrong/empty during the rebuild. Not part of any default fast-pass.

---

## 4. Hard "do not" list for optimizations

- **No UI/visual changes, ever** — no reduce-motion, no animation disabling, no Dock/menubar/transparency/
  font-smoothing tweaks.
- **Never** run periodic `daily`/`weekly`/`monthly` scripts — REMOVED in modern macOS; `launchd` handles
  maintenance automatically.
- **Never** `sfltool resetbtm` (nuclear), `mdutil -E` as routine (reindex storm), `atsutil databases -remove` /
  `lsregister -kill -r` unless symptom-driven.
- **Never** `bootout` a `com.apple.*` label; always confirm with `launchctl print` first.
- **Never** chain a read-only diagnostic line into a mutating action (`osascript quit`, `launchctl bootout`) —
  separate, approve, then act.
- **Never** disable swap or use third-party memory cleaners on 8 GB.
- See `safety-do-not-delete.md` for the disk/data protection policy (including the protected `~/.claude` and
  your configured protect paths).

---

## 5. BSD-userland correctness (macOS, bash 3.2)

- `du` has **NO `-b`** flag — use `-sh` or `-sk`/`-d` (GNU `du -b` errors on macOS).
- `ps` has **NO GNU `--sort`** — use `ps aux -m` for a memory sort.
- `stat` uses **`-f`**, not `-c`.
- `find -size` accepts `M`/`G` suffixes but not `-b`.
- Under bash 3.2 + `set -u`, guard empty-array expansion: `${arr[@]+"${arr[@]}"}`.
- `sort -rh` IS supported on macOS sort.
- `readlink -f` works on recent macOS, but for portability to older releases prefer
  `python3 -c 'import sys;print(sys.executable)'` or `cd "$(dirname "$(which python3)")" && pwd -P`.
- Terminal needs **Full Disk Access** (System Settings > Privacy & Security) before `tmutil` snapshot commands
  work on recent macOS.
