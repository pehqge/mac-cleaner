# Safety & Trust

> **Short version:** These scripts are read-only by default, never connect to the internet, never run
> hidden commands, and never delete anything without showing you the exact command first and waiting for
> your explicit approval. Everything is plain, auditable Bash you can read in a few minutes. This document
> explains *why* that is true and shows you how to verify it yourself.

If you are about to run a cleanup tool on your own Mac, you are right to be cautious. A cleaner has, by
definition, the power to delete files. This page exists so you can trust it for the right reasons — because
you checked — not because a README told you to.

---

## Table of contents

- [The five guarantees](#the-five-guarantees)
- [No malware, no phone-home](#no-malware-no-phone-home)
- [How nothing gets deleted by surprise](#how-nothing-gets-deleted-by-surprise)
- [How your sensitive data is protected](#how-your-sensitive-data-is-protected)
- [How it avoids breaking your Mac](#how-it-avoids-breaking-your-mac)
- [What each script does](#what-each-script-does)
- [About `sudo`](#about-sudo)
- [About `eval`](#about-eval-the-one-that-looks-scary)
- [Verify it yourself in 2 minutes](#verify-it-yourself-in-2-minutes)
- [What this tool will never do](#what-this-tool-will-never-do)

---

## The five guarantees

1. **Read-only first.** The default action of every script is to *look*, not touch. `scan.sh` only reads.
   `clean.sh` with no flags only previews. `optimize.sh` with no flags only audits. You have to explicitly
   ask for changes with `--apply`.
2. **Nothing runs you haven't seen.** Before any deletion, the exact command is printed on screen. Then you
   type `apply` to confirm, and each riskier item is confirmed again, one at a time.
3. **No network, ever.** The scripts make zero internet connections. No downloads, no uploads, no telemetry,
   no analytics. They work fully offline (turn off Wi-Fi and run them — identical result).
4. **Your data is protected by design.** A protect-list excludes `~/.claude`, Claude Code's own cache, and
   anything you add. Photos, Mail, messages, iOS backups, and system files are never deletion targets.
5. **It's all readable Bash.** No compiled binary, no obfuscation, no encoded payloads. Three plain text
   files, ~1,300 lines total, that you can read end-to-end.

---

## No malware, no phone-home

The most important property of a tool with delete power is that it does only what it says. Here is how you
can be sure:

- **No network code.** There is no `curl`, `wget`, `nc`, `ssh`, `scp`, or any networking command anywhere in
  the scripts. Verify:
  ```bash
  grep -nE '\b(curl|wget|nc|ssh|scp|ftp|telnet)\b' scripts/*.sh
  # → prints nothing
  ```
- **No obfuscation.** There is no `base64` decoding, no "download a script and pipe it to bash", no minified
  blobs. Verify:
  ```bash
  grep -nE 'base64|curl.*\| *(sh|bash)|\| *(sh|bash) *$' scripts/*.sh
  # → prints nothing
  ```
- **No telemetry.** Nothing is logged anywhere except your own terminal. No files are written to track you;
  the only files the scripts create are short-lived temp files (via `mktemp`) used to sort the report, and
  they are deleted at the end of the run.
- **It's open and pinned to a commit.** You can read every line on GitHub and check out the exact commit you
  are running. There is no install step that fetches remote code.

The scripts are also designed to fail *safe*. They run with `set -euo pipefail`, and every size-scan pipeline
is made tolerant so that one unreadable system path is skipped rather than crashing the run — a scanner
should never abort halfway and leave you guessing.

---

## How nothing gets deleted by surprise

Deletion only ever happens in `clean.sh`, and only along a deliberately narrow path:

1. **Default is a dry-run.** `./scripts/clean.sh` deletes nothing. It builds a plan and prints it. The header
   literally says `MODE: DRY-RUN (preview only — nothing will be deleted)`.
2. **You must opt in.** Deletion requires `--apply`.
3. **The exact commands are printed.** Before running, you see the full list of commands that *will* run,
   character for character — e.g. `rm -rf "/Users/you/.npm/_npx"`.
4. **You type a word to confirm.** The script waits for you to type exactly `apply`. Anything else aborts.
5. **Risky items are confirmed individually.** "Safe" items (regenerable caches) run as a batch; every
   "Review" item asks `delete this one? [y/N]` separately, so you decide per item.
6. **A last-line guard refuses protected paths.** Even after all that, immediately before each `rm`, the
   script re-checks the command against the protect-list and *skips* it if a protected path somehow appears.
   This is defense-in-depth: the protected path is filtered at scan time, at plan time, and again at execute
   time.
7. **Two commands are permanently blocked.** The script will never delete an active Python virtualenv your
   `python3` lives in, and never blanket-wipe `~/Library/Logs` (which holds Claude logs and crash reports).

The riskiest items — `sleepimage`, iOS device backups, Docker volumes — are **never run by the script at
all**. They are printed as documentation, with their exact commands and tradeoffs, for you to run yourself,
deliberately, one at a time, only if you choose to.

---

## How your sensitive data is protected

The tool draws a hard line between **regenerable junk** (caches, build artifacts, stale downloads) and
**your data** (photos, messages, mail, documents, backups). Your data is never a target.

- **Protected paths are excluded at every stage** — scan, plan, and execute. By default this includes
  `~/.claude` and Claude Code's own cache. You can add your own (a browser profile, a password vault, a
  working directory) without editing any script:
  ```bash
  cp scripts/local.config.example.sh scripts/local.config.sh
  # add your paths to PROTECT_EXTRA=(...) — this file is git-ignored, never committed
  ```
  You can also protect a directory for a single run with `--ignore <dir>`.
- **User data is awareness-only.** Photos Library, WhatsApp/Telegram/Signal containers, the Mail store, and
  similar are reported (so you know what's large) but are **never** offered for deletion.
- **iOS backups need per-device confirmation.** They may hold Health/Keychain data that isn't in iCloud, so
  they are Caution-tier and never auto-deleted.
- **Risk tiers, always visible.** Every item is labelled **Safe** (regenerable), **Review** (verify first),
  or **Caution** (real tradeoff). When the tool is unsure, it downgrades to the stricter tier.

---

## How it avoids breaking your Mac

A cleaner can "break" a Mac in subtle ways — deleting something the OS needs, removing a toolchain a project
depends on, or disabling a service you rely on. The scripts are built to avoid each of these:

- **System and SIP paths are off-limits.** `/System`, the root `/Library`, system LaunchDaemons/Agents, and
  the active swap files are never touched.
- **No UI or visual changes, ever.** The tool will not touch reduced motion, animations, the Dock, the menu
  bar, font smoothing, or wallpaper. Optimizations only affect background work.
- **Tool-native prunes over blunt deletes.** Where a tool knows what's safe to remove, the script uses it:
  `pnpm store prune`, `uv cache clean`, `brew cleanup`, `xcrun simctl delete unavailable`. These remove only
  unreferenced/regenerable data.
- **Active toolchains are kept.** Rust toolchain removal keeps both your default and the one your current
  project pins, and warns when a project pins a version.
- **Corrupt-only, never blanket.** Broken-preference cleanup only offers plists that actually fail
  `plutil -lint` (a corrupt plist makes its app fall back to defaults anyway). Log cleanup only offers
  third-party logs older than 30 days, never Claude's or crash reports.
- **No heavy rebuilds by default.** Operations that trigger CPU/IO storms (Spotlight reindex, font-cache
  rebuild, LaunchServices rebuild) are printed as *guidance only* and are never auto-run.
- **Honest about rebuild costs.** When deleting something forces a slow re-download or rebuild (Docker
  layers, package caches), the tool says so up front.

Worst realistic case if you approve a Safe item you didn't need to: a cache is rebuilt the next time the
relevant app runs. Nothing irreplaceable is in the Safe tier.

---

## What each script does

### `scripts/scan.sh` — read-only deep scan
**Mutates nothing. Safe to run anytime, as often as you like.** It reads disk usage (including true APFS free
space), RAM and swap pressure, the top memory consumers, and the sizes of regenerable caches and junk —
then prints a report grouped Safe / Review / Caution, largest first. It also surfaces unavailable Xcode
simulator runtimes, stale logs, corrupt preferences, and broken login items. The only writes it makes are
temporary sort files via `mktemp`, removed before it exits.

### `scripts/clean.sh` — dry-run-by-default cleanup
**Previews by default; deletes only with `--apply` + your typed confirmation.** It builds a plan of
regenerable caches and junk, prints each item with its size and the exact command, and — only after you opt
in and confirm — removes the approved items, confirming each Review item individually. It captures
before/after free space and reports the real delta. It refuses protected paths and blocks the two dangerous
commands described above. Selection can also be driven item-by-item (`--plan-tsv` to list, `--apply
--select <ids>` to apply only a chosen subset).

### `scripts/optimize.sh` — background/performance audit
**Read-only audit by default; opt-in tweaks only with `--apply`, each confirmed.** It reports login items,
background launch agents, Homebrew services, Spotlight status, power-management settings, and broken login
items. With `--apply` it can, only after an explicit `yes` per action, flush DNS, disable Power Nap and
proximity wake (reversible), run `sudo purge`, or boot out one reviewed user login item. It never writes a UI
setting and never disables swap. Heavy rebuilds are guidance-only and never auto-run.

---

## About `sudo`

- **`scan.sh` and `clean.sh` never run `sudo`.** (Any `sudo` text you see in them lives inside printed notes
  and the Caution documentation block — it is shown to you, not executed.)
- **`optimize.sh` only uses `sudo` under `--apply`,** and every single `sudo` action asks for an explicit
  `yes` first — even if you passed `--yes`. The default audit mode runs no privileged command at all.
- Privileged actions are limited to a small, named set: DNS flush, `pmset` power tweaks (reversible),
  `purge`, and booting out a non-Apple login item you name. Apple system labels are refused outright.

---

## About `eval` (the one that looks scary)

You'll find `eval` in the scripts. `eval` *can* be dangerous, so here is exactly what it does here — nothing
hidden:

1. `eval echo "~$(id -un)"` — resolves your home directory when `$HOME` is missing. It expands `~yourname`
   to a path. No external input is involved.
2. `eval "$cmd"` in `clean.sh` — runs one of the plan commands. Crucially, `$cmd` is **only ever a string the
   script itself built and already printed to you** in the plan. It is not built from file contents, network
   data, or anything an attacker controls. The command was shown on screen, you typed `apply`, and (for
   Review items) you confirmed it individually — *then* it runs, after the protected-path guard re-checks it.

In other words, `eval` here is the execution step of "run the exact thing you just approved," not a way to
run anything unseen.

---

## Verify it yourself in 2 minutes

Don't take this document's word for it. Run these from the repo root:

```bash
# 1. No network / remote-exec code anywhere:
grep -nE '\b(curl|wget|nc|ssh|scp|ftp|telnet)\b|base64|curl.*\|' scripts/*.sh

# 2. See every place a delete can happen, with full context:
grep -nE '\brm (-rf|-f)\b' scripts/*.sh

# 3. Confirm scan.sh and clean.sh never execute sudo (matches are notes/docs only):
grep -n 'sudo' scripts/scan.sh scripts/clean.sh

# 4. Watch a real dry-run delete nothing (no --apply):
./scripts/scan.sh        # read-only
./scripts/clean.sh       # preview only — ends with "Nothing was deleted."

# 5. Read the whole thing. It's short:
wc -l scripts/*.sh
```

If step 4's `clean.sh` prints anything other than a preview that ends without deleting, stop and open an
issue. It shouldn't — but you should be able to confirm it does what's claimed.

---

## What this tool will never do

- ❌ Connect to the internet, upload data, or run remote code.
- ❌ Delete a file without printing the exact command and getting your explicit `apply`.
- ❌ Touch `~/.claude`, Claude Code's cache, or anything in your protect-list.
- ❌ Delete Photos, Mail, messages, documents, or iOS backups as part of any batch.
- ❌ Modify `/System`, the root `/Library`, SIP paths, or active swap.
- ❌ Change any UI/visual setting (motion, animations, Dock, menu bar, fonts).
- ❌ Run `sudo` silently, or run any privileged command without a per-action `yes`.
- ❌ Strip universal binaries or language files (re-signing risk) — deliberately excluded.

If you find anything that contradicts the above, that's a bug worth reporting — please open an issue.
