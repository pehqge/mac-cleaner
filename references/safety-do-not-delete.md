# Safety & DO-NOT-DELETE Reference

The authoritative protection list for this toolkit. **When in doubt, do not delete.** Every destructive action
is summary-first, dry-run by default, and requires explicit approval. Read-only first, zero data loss.

---

## 0. Protected paths (the never-touch list)

Exclude these from **every** `find`, scan, and clean command. Never touch, never suggest deleting, never even
list as a candidate.

| Path | Why |
|---|---|
| `~/.claude` | **PROTECTED.** Claude Code data/config/projects (this toolkit is agent-driven). Seed it into the exclude list of every scan. This also covers `~/Library/Logs/Claude` — exclude it from any log cleanup. |
| _your configured paths_ | Anything you add to the script's user protect list or pass via `--ignore` — e.g. a browser profile, a password-manager vault, an active working directory. Treat as sacred. |

**Implementation note for any scan/clean loop:** add explicit guards, e.g. `! -path '*/.claude/*'` (plus a
clause per configured protect path), to any `find`. When iterating paths, use NUL-delimited iteration so odd
characters can't mis-target:
```bash
find ~ -name node_modules -type d -prune \
  ! -path '*/.claude/*' -print0 2>/dev/null \
  | while IFS= read -r -d '' d; do du -sh "$d"; done | sort -rh | head -30
```
(The naive `... | while read d; do ...` lacks `-r`, lacks IFS reset, and is not NUL-delimited — harmless with
`du` but dangerous if ever reused for `rm`. Always harden before any deletion.)

> Tip: to protect a browser profile or other app data, add it to the `PROTECT` list at the top of the scripts
> or pass `--ignore "$HOME/Library/Application Support/<App>"`.

---

## 1. Full DO-NOT-DELETE list (with reasons)

### User data — never auto-delete (only opt-in, in-app levers)
| Path | Reason / only safe lever |
|---|---|
| `~/Pictures/Photos Library.photoslibrary` | Real photo data. Direct `rm` risks irreversible loss. Only lever: Photos.app > Settings > iCloud > **Optimize Mac Storage** (evicts originals to iCloud, keeps thumbnails) — opt-in, needs iCloud space. |
| Messaging-app containers (`~/Library/Group Containers/*WhatsApp*`, Telegram, Signal, etc.) | Chats/media. User data. Never auto-delete. |
| `~/Library/Mail` (and any account mail store) | Only the **Mail Downloads** cache is ever clearable, never the mail store itself. |
| `~/Library/Application Support/MobileSync/Backup/<UUID>` | Local iOS device backups. **Caution / per-UUID approval only.** iCloud Backup is NOT equivalent — local encrypted backups hold Health/Keychain/passwords that iCloud backup omits. Deleting the sole backup of a device no longer in hand is irreversible. Identify device + date (Info.plist) and confirm a current alternative exists before any per-UUID `rm`. Read-only sizing is fine: `du -sh ~/Library/Application\ Support/MobileSync/Backup/*/ 2>/dev/null \| sort -rh`. |

### An active virtualenv your `python3` resolves into — BLOCKED by default
| Path | Reason |
|---|---|
| a venv under `$HOME` (e.g. `~/venv`, `~/.venvs/<name>`) | If `which python3` resolves **into** a venv that is first on your `PATH`, that venv is your **live interpreter**. `rm -rf <venv>` is a **BLOCKED command** — it breaks every shell `python3`, any tool with a `#!<venv>/bin/python3` shebang, and all pip packages installed into it, immediately and irreversibly. |

**How to detect it (read-only):**
```bash
which python3
python3 -c 'import sys; print(sys.prefix, sys.executable)'   # portable; prefer over `readlink -f`
```
If `sys.prefix` points to a directory under `$HOME` (not `/usr`, `/opt/homebrew`, or an Xcode path), treat that
directory as a live venv and protect it.

**Only-if-reclaiming procedure (Caution, explicit approval, never default):**
```bash
# 1) export the installed packages so the env is reproducible:
<venv>/bin/pip freeze > ~/requirements-backup.txt
# 2) remove the venv from PATH / shell rc, open a new shell, and confirm:
which python3                                  # must no longer point into the venv
python3 -c 'import sys; print(sys.executable)'
# 3) only then, with explicit approval:
# rm -rf <venv>
```

### System-managed / OS-owned — never delete manually
| Path / item | Reason |
|---|---|
| `com.apple.os.update-*` local APFS snapshots | OS-updater **staging** snapshots, `Purgeable: No`, system-managed. macOS auto-clears them after the update settles. Manually deleting them is unsafe and usually reclaims nothing. `tmutil disablelocal` is dead — do not use it. Read-only view: `tmutil listlocalsnapshots /`. |
| `/private/var/vm/swapfile*` | Active OS swap. Never delete while running (released on reboot). On 8 GB, never disable the pager. |
| `/private/var/vm/sleepimage` | **Caution — do not touch by default.** See section 2. |
| `/System`, `/Library` (root), `/System/Library/LaunchDaemons`, `/System/Library/LaunchAgents` | SIP-protected. |
| `kernel_task`, `WindowServer`, `loginwindow` (processes) | Never kill. `kernel_task` is the thermal governor. |
| `~/Library/Developer/Xcode/Archives` | Signed app archives are the **only** copy, not regenerable. |

---

## 2. High-severity Caution items (explicit approval + tradeoff warning required)

### sleepimage / hibernation
A typical safe-sleep config is `hibernatemode 3` (RAM mirrored to disk) + `standby 1` on battery.
```bash
# Check (read-only):
ls -lah /private/var/vm/sleepimage
pmset -g | grep hibernatemode
```
- `sudo pmset -a hibernatemode 0 && sudo rm -f /private/var/vm/sleepimage` reclaims the file but **disables
  safe-sleep**: if the battery fully drains during sleep, all unsaved in-RAM work is **lost** (no hibernation
  image to restore).
- **RECOMMENDED DEFAULT: leave `hibernatemode` at 3.** Offer mode 0 only as explicit opt-in with the tradeoff
  stated. Deleting the sleepimage alone is pointless — it regenerates on next sleep unless the mode is changed.
- Do **not** pin an immutable empty file (overly aggressive).

### Docker `--volumes`
- `docker system prune -a --volumes` permanently destroys local dev-data volumes (e.g. a Postgres dev DB)
  counted as "unused" — real, non-regenerable data loss.
- **Fix:** drop `--volumes` by default. Review first, do not chain:
```bash
# Daemon must be running first. Review (read-only):
docker system df
docker volume ls
# Action (NO --volumes by default; only add it after confirming no dev-data volumes exist):
docker system prune -a
docker buildx prune -f      # build cache only — regenerable, safe
```
- Note: `docker system prune` only reclaims logical space **inside** the VM; the `Docker.raw` sparse file does
  not shrink without Docker Desktop "Reset to factory defaults" or a full uninstall. Biggest win if Docker is
  unused day-to-day is uninstalling it.

### Local iOS backups
See the MobileSync row in section 1 — per-UUID approval, identify device+date, confirm an alternative copy first.

---

## 3. BLOCKED commands (never emit without their fix)

| Blocked command | Why blocked | Required fix |
|---|---|---|
| `rm -rf <active venv>` | It may be your **live `python3`**. Deleting breaks the interpreter and all its packages irreversibly. | Detect via `python3 -c 'import sys;print(sys.prefix)'`. Export `pip freeze`, re-point `python3`, verify `which python3` no longer points into it, then delete only with explicit approval. (Section 1.) |
| `rm -rf ~/Library/Logs/*` | **Wipes `~/Library/Logs/Claude` (protected)** and blanket-deletes `DiagnosticReports`, `CoreSimulator`, updater logs, `fsck_hfs.log` — some are exactly the diagnostics needed for RAM/perf work. | Never blanket-delete. Preview stale third-party logs only, excluding Claude and DiagnosticReports: `find ~/Library/Logs -mindepth 1 -maxdepth 1 -mtime +30 ! -name Claude ! -path '*Claude*' ! -name DiagnosticReports -print`, then remove individually with approval. |

---

## 4. macOS protections you must respect

### SIP (System Integrity Protection)
`/System`, large parts of `/usr`, `/Library/LaunchDaemons` (system), and signed Apple binaries are protected by
SIP. Writes/deletes there fail by design — never try to work around SIP. Skip these paths entirely.

### Signed system volume (SSV)
The boot volume `/` is a **cryptographically sealed read-only snapshot**. This is why `mdutil -s /` reports the
`/` index as read-only — **that is NORMAL, not an error.** Only the **Data** volume (`/System/Volumes/Data`) is
writable/indexable. Never try to delete from or reindex `/`.

### iCloud "evicted" / purgeable files
- With iCloud Drive / Photos "Optimize Mac Storage" on, file originals can be **evicted** to iCloud — a local
  stub remains and the file re-downloads on access. Deleting these locally is meaningless (they're already
  offloaded) and can trigger surprise re-downloads.
- **APFS purgeable space:** `df -h` *understates* true free space because it ignores purgeable. Use
  `diskutil info /` for ground truth before estimating reclaim.

### Full Disk Access
Terminal needs Full Disk Access (System Settings > Privacy & Security) before `tmutil` snapshot commands work
on recent macOS. Grant it if `tmutil` errors.

---

## 5. Scan first — never assume a "win" exists

Many widely-cited cleanup targets are empty/absent on a given machine: CoreSpotlight metadata, QuickLook
thumbnailcache, Safari TabSnapshots, pip cache, bun cache, CocoaPods cache, Xcode DerivedData. **Measure each
with `du -sh` before proposing it.** Never present an item the scan didn't actually find populated.

---

## 6. Partial-delete cautions (safe target, but mind the scope)

- `~/.npm/_npx` is safe to wipe, but **do NOT `rm -rf ~/.npm` wholesale** — that nukes real npm config/cache.
  Only `_npx` is disposable.
- `brew autoremove && brew cleanup -s` is rejected as a chain (autoremove can silently drop a
  transitively-installed CLI you rely on, then cleanup scrubs the cache so reinstall needs a fresh download).
  Fix: `brew autoremove -n` (preview) → approve → `brew autoremove` → separately `brew cleanup -s --prune=0`.
  Never chain with `&&`.
- `~/Downloads/*/.next` and project `node_modules` are regenerable, but confirm no `next dev`/dev server is
  running against them before deleting (`lsof +D <path>/.next`), and that the project has a committed lockfile
  for a reproducible reinstall.
- `rustup toolchain uninstall <name>` is safe only after confirming it's neither the configured default nor the
  cwd-active toolchain, and that no project pins its **channel**: `grep -rl '<channel>' <project-roots>/rust-toolchain* 2>/dev/null`
  (pins reference the channel/version, e.g. `1.94.0`, not the full target triple).
- Quote paths with spaces fully, e.g. `rm -rf "$HOME/Library/Application Support/Google/GoogleUpdater/crx_cache"/*`,
  rather than backslash-escaping.
- `fclones` on APFS: use **hard-link** dedupe, NOT reflink/`--dedupe` (copy-on-write block sharing is
  unsupported on macOS APFS). Always review `dupes.txt` before remove. `dua-cli`/`gdu` delete via `unlink`,
  **not Trash** — confirm paths.
