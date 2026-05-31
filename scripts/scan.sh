#!/usr/bin/env bash
#
# scan.sh — READ-ONLY deep disk + RAM scan for Apple Silicon Macs (M-series, arm64).
#
# This script NEVER deletes, moves, or modifies anything. It only reads sizes and state
# and prints a categorized report sorted largest-first.
#
# HARD CONSTRAINTS (never violated):
#   - Every path in the PROTECT list (below) is excluded from every "deletable" listing
#     and reported only under a "protected (never delete)" banner. ~/.claude is protected
#     by default; add your own (browser profile, vault, working dir) in the PROTECTED array.
#   - No UI/visual changes are ever suggested or made.
#
# macOS BSD-userland correct:
#   - du -sh / du -k only (NO -b). stat -f (NO -c). sort -rh / -k. find -size with M/G.
#   - Works under bash 3.2 with `set -u`: every array expansion is guarded with
#     ${arr[@]+"${arr[@]}"} so an empty array does not trip "unbound variable".
#
set -euo pipefail
# NOTE: this is a READ-ONLY scanner that runs `du`/`find` across many paths, some
# unreadable (SIP / permission-denied) — those exit non-zero. With `-e` + pipefail
# a single unreadable path would abort the whole report, which is wrong for a
# diagnostic. So every size/scan pipeline below is made explicitly tolerant with a
# trailing `|| true` (and `du ... | awk ... || printf 0` for arithmetic), so one
# bad path is skipped, not fatal. `set -u` still catches unbound vars; all array
# expansions are guarded with ${arr[@]+"${arr[@]}"} for bash 3.2 safety.

# ----------------------------------------------------------------------------
# Phase 0 — Preflight
# ----------------------------------------------------------------------------

# Resolve the real home directory (do not trust a stale $HOME blindly, but prefer it).
HOME_DIR="${HOME:-$(/usr/bin/env -i sh -c 'echo ~' 2>/dev/null || true)}"
if [ -z "${HOME_DIR}" ] || [ ! -d "${HOME_DIR}" ]; then
  HOME_DIR=$(eval echo "~$(id -un)")
fi

# Protected paths — NEVER listed as deletable, only reported as protected.
# Customize for your setup: add any directory you never want touched (a browser
# profile, a password-manager vault, an active working dir). ~/.claude is protected
# by default because this toolkit is agent-driven.
PROTECTED=(
  "${HOME_DIR}/.claude"
  # Examples — uncomment / edit to protect your own data:
  # "${HOME_DIR}/Library/Application Support/Arc"
  # "${HOME_DIR}/Library/Caches/Arc"
)

# Merge optional personal config (git-ignored, never published). Set PROTECT_EXTRA
# in scripts/local.config.sh to add your own protected paths without editing this file.
_SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || printf '.')
if [ -f "${_SCRIPT_DIR}/local.config.sh" ]; then
  # shellcheck disable=SC1091
  . "${_SCRIPT_DIR}/local.config.sh"
  for _x in ${PROTECT_EXTRA[@]+"${PROTECT_EXTRA[@]}"}; do
    [ -n "$_x" ] && PROTECTED+=("$_x")
  done
fi

# Color/format helpers (degrade gracefully if not a tty).
if [ -t 1 ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
  C=$(printf '\033[36m'); Y=$(printf '\033[33m'); G=$(printf '\033[32m')
else
  B=""; D=""; R=""; C=""; Y=""; G=""
fi

hr()      { printf '%s\n' "------------------------------------------------------------------------"; }
section() { printf '\n%s%s== %s ==%s\n' "$B" "$C" "$1" "$R"; }
sub()     { printf '\n%s-- %s --%s\n' "$B" "$1" "$R"; }
note()    { printf '%s  %s%s\n' "$D" "$1" "$R"; }

# is_protected <path> -> returns 0 if the path is (or is inside) a protected dir.
is_protected() {
  local target="$1" p
  for p in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
    case "$target" in
      "$p"|"$p"/*) return 0 ;;
    esac
  done
  return 1
}

# size_of <path> -> prints "<human-size>\t<path>" if it exists, else nothing.
# Skips protected paths entirely (defense in depth — protected dirs are never sized here).
size_of() {
  local path="$1"
  [ -e "$path" ] || return 0
  if is_protected "$path"; then return 0; fi
  du -sh "$path" 2>/dev/null || true
}

# kb_of <path> -> prints size in KiB (BSD du -k) for arithmetic; 0 if missing.
kb_of() {
  local path="$1"
  [ -e "$path" ] || { printf '0'; return 0; }
  if is_protected "$path"; then printf '0'; return 0; fi
  du -sk "$path" 2>/dev/null | awk '{print $1; exit}' || printf '0'
}

printf '%s%s' "$B" "$C"
cat <<'BANNER'
========================================================================
  mac-cleaner :: READ-ONLY DEEP SCAN
  No file is deleted, moved, or modified by this script.
========================================================================
BANNER
printf '%s' "$R"
note "Home: ${HOME_DIR}"
note "Date: $(date '+%Y-%m-%d %H:%M:%S')"

# ----------------------------------------------------------------------------
# Protected-paths banner (sizes shown only so the user knows they are large &
# intentionally untouched).
# ----------------------------------------------------------------------------
section "PROTECTED — never deleted, never in any clean menu"
for p in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
  if [ -e "$p" ]; then
    du -sh "$p" 2>/dev/null || true
  fi
done
note "These are protected (see the PROTECTED list in this script). Reported for awareness only."

# ----------------------------------------------------------------------------
# Phase 1a — Disk usage & true free space (APFS purgeable)
# ----------------------------------------------------------------------------
section "DISK — df + APFS true free space"
df -h / 2>/dev/null || true
sub "diskutil info / (APFS ground truth — purgeable / free)"
# df understates APFS free space (ignores purgeable). diskutil is the ground truth.
diskutil info / 2>/dev/null | grep -iE 'Container Free Space|Free Space|Volume Free Space|Purgeable|Allocated' || \
  note "diskutil info / produced no Free/Purgeable lines."

# ----------------------------------------------------------------------------
# Local APFS snapshots (read-only). com.apple.os.update-* are OS-update staging.
# ----------------------------------------------------------------------------
section "APFS LOCAL SNAPSHOTS (read-only)"
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null || true)
if [ -n "$SNAPS" ]; then
  printf '%s\n' "$SNAPS"
  if printf '%s' "$SNAPS" | grep -q 'com.apple.os.update'; then
    note "com.apple.os.update-* snapshots are OS-updater staging (Purgeable:No, system-managed)."
    note "NEVER delete these manually — macOS clears them after the update settles."
  fi
  if printf '%s' "$SNAPS" | grep -q 'com.apple.TimeMachine'; then
    note "Genuine TimeMachine.*.local hourly snapshots present — these CAN be thinned if space is needed:"
    note "  sudo tmutil thinlocalsnapshots / 20000000000 4   (urgency 4 = most aggressive)"
  fi
else
  note "No local snapshots reported (or Full Disk Access not granted to the terminal)."
  note "If tmutil errored: grant Full Disk Access in System Settings > Privacy & Security."
fi

# ----------------------------------------------------------------------------
# Phase 1b — RAM / memory pressure (the real bottleneck on 8GB)
# ----------------------------------------------------------------------------
section "MEMORY / RAM PRESSURE (read-only) — the real bottleneck on 8GB"
sub "memory_pressure"
memory_pressure 2>/dev/null | grep -iE 'System-wide|free percentage|pages|pressure' || memory_pressure 2>/dev/null || true
sub "swap usage (sysctl vm.swapusage)"
SWAP=$(sysctl -n vm.swapusage 2>/dev/null || true)
printf '%s\n' "${SWAP:-unavailable}"
# Flag red-zone: parse "used = X.XXM/G". If used >~ 80% of total, warn.
if [ -n "$SWAP" ]; then
  USED_RAW=$(printf '%s' "$SWAP" | sed -n 's/.*used = \([0-9.]*[MG]\).*/\1/p')
  TOTAL_RAW=$(printf '%s' "$SWAP" | sed -n 's/.*total = \([0-9.]*[MG]\).*/\1/p')
  to_mb() { # arg like 6.78G or 455.00M
    local v="$1" n u
    n=$(printf '%s' "$v" | sed 's/[MG]$//')
    u=$(printf '%s' "$v" | sed 's/[0-9.]//g')
    case "$u" in
      G) awk -v n="$n" 'BEGIN{printf "%.0f", n*1024}' ;;
      M) awk -v n="$n" 'BEGIN{printf "%.0f", n}' ;;
      *) printf '0' ;;
    esac
  }
  if [ -n "$USED_RAW" ] && [ -n "$TOTAL_RAW" ]; then
    UM=$(to_mb "$USED_RAW"); TM=$(to_mb "$TOTAL_RAW")
    if [ "${TM:-0}" -gt 0 ]; then
      PCT=$(awk -v u="$UM" -v t="$TM" 'BEGIN{printf "%.0f", (u/t)*100}')
      if [ "${PCT:-0}" -ge 80 ]; then
        printf '%s  !! RED ZONE: swap %s%% used (%s of %s). RAM pressure is real.%s\n' "$Y" "$PCT" "$USED_RAW" "$TOTAL_RAW" "$R"
        note "No disk cleanup frees RAM. Only quitting idle apps + trimming login items helps."
        note "See: scripts/optimize.sh (RAM relief is opt-in there)."
      fi
    fi
  fi
fi
sub "top memory consumers (ps aux -m — BSD memory sort)"
# NUL-safe not needed (read-only). ps aux -m is the BSD memory sort (no GNU --sort).
ps aux -m 2>/dev/null | head -16 || true

# ----------------------------------------------------------------------------
# Phase 1c — Per-category sizes, collected then sorted largest-first.
# Each entry: "<group>|<label>|<path>"  — path may be a glob target dir.
# We size each present, non-protected path and print sorted by KiB desc.
# ----------------------------------------------------------------------------

# Helper: print a sized, sorted table for a set of "label|path" rows.
# Args are passed as repeated label and path pairs via stdin lines "label<TAB>path".
print_sized_table() {
  # reads "label<TAB>path" lines on stdin, prints "size  label  (path)" sorted desc
  local line label path kb human
  local tmp
  tmp=$(mktemp 2>/dev/null || printf '/tmp/mc_scan_%s' "$$")
  : > "$tmp"
  while IFS=$'\t' read -r label path; do
    [ -n "$path" ] || continue
    # Expand a single leading ~ if present (paths here are pre-expanded, but be safe).
    case "$path" in "~"/*) path="${HOME_DIR}/${path#~/}" ;; esac
    [ -e "$path" ] || continue
    if is_protected "$path"; then continue; fi
    kb=$( { du -sk "$path" 2>/dev/null || true; } | awk '{print $1; exit}')
    [ -n "$kb" ] || continue
    human=$( { du -sh "$path" 2>/dev/null || true; } | awk '{print $1; exit}')
    printf '%s\t%s\t%s\t%s\n' "$kb" "$human" "$label" "$path" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    sort -t$'\t' -k1,1 -rn "$tmp" | while IFS=$'\t' read -r kb human label path; do
      printf '  %8s   %-42s %s%s%s\n' "$human" "$label" "$D" "$path" "$R"
    done
  else
    note "(nothing present in this category)"
  fi
  rm -f "$tmp" 2>/dev/null || true
}

H="$HOME_DIR"

section "PACKAGE MANAGER CACHES (Safe — regenerable)"
print_sized_table <<EOF
pnpm content-addressable store	${H}/Library/pnpm/store
npm npx one-off cache (_npx)	${H}/.npm/_npx
npm cache (_cacache — keep config)	${H}/.npm/_cacache
yarn cache	${H}/Library/Caches/Yarn
pip cache	${H}/Library/Caches/pip
Homebrew download cache	${H}/Library/Caches/Homebrew
bun install cache	${H}/.bun/install/cache
Go module cache	${H}/go/pkg/mod/cache
uv cache	${H}/.cache/uv
uv data (toolchains+tools — NOT pure cache)	${H}/.local/share/uv
EOF
note "Homebrew cache true path: run 'brew --cache'. _npx is pure junk; _cacache holds real npm cache."
note "~/.local/share/uv holds uv-managed Python toolchains — size shown, but do NOT rm it."

section "DEVELOPER TOOL CACHES (Safe / Review)"
print_sized_table <<EOF
Gradle caches	${H}/.gradle/caches
CocoaPods cache	${H}/Library/Caches/CocoaPods
Carthage cache	${H}/Library/Caches/org.carthage.CarthageKit
Cargo registry	${H}/.cargo/registry
Cargo git checkouts	${H}/.cargo/git
Rustup toolchains (all)	${H}/.rustup/toolchains
Google Updater (crx_cache is the bulk)	${H}/Library/Application Support/Google/GoogleUpdater
EOF
sub "Rust toolchains (rustup) — keep the active/default one"
if command -v rustup >/dev/null 2>&1; then
  rustup toolchain list 2>/dev/null || true
  for d in "${H}/.rustup/toolchains/"*/; do
    [ -d "$d" ] || continue
    du -sh "$d" 2>/dev/null || true
  done
else
  note "rustup not installed."
fi

section "XCODE & APPLE DEVELOPMENT"
print_sized_table <<EOF
Xcode DerivedData	${H}/Library/Developer/Xcode/DerivedData
Xcode Archives (CAUTION — only copy)	${H}/Library/Developer/Xcode/Archives
iOS DeviceSupport	${H}/Library/Developer/Xcode/iOS DeviceSupport
CoreSimulator caches	${H}/Library/Developer/CoreSimulator/Caches
Xcode app cache	${H}/Library/Caches/com.apple.dt.Xcode
EOF
note "These are often empty/absent — the table above shows current state. Scan first, never assume."
note "Archives are signed app archives (NOT regenerable) — Caution, never auto-delete."

section "DOCKER"
if [ -e "${H}/Library/Containers/com.docker.docker" ]; then
  size_of "${H}/Library/Containers/com.docker.docker"
  RAW="${H}/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  if [ -e "$RAW" ]; then
    ls -lh "$RAW" 2>/dev/null || true
    note "Docker.raw sparse image. 'docker system prune' only frees space INSIDE the VM;"
    note "the .raw file does not shrink without Docker 'Reset to factory' or uninstall."
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    note "Docker daemon is RUNNING — 'docker system df' below is live."
    docker system df 2>/dev/null || true
  else
    note "Docker daemon is NOT running. Biggest win is uninstalling Docker Desktop if unused."
  fi
else
  note "Docker Desktop not present."
fi

section "BROWSERS (informational — any protected browser dirs are excluded)"
print_sized_table <<EOF
Chrome cache	${H}/Library/Caches/Google/Chrome
Chrome profile (user data — review only)	${H}/Library/Application Support/Google/Chrome
Brave cache	${H}/Library/Caches/BraveSoftware
Firefox cache	${H}/Library/Caches/Firefox
Arc cache	${H}/Library/Caches/Arc
Safari (managed by macOS)	${H}/Library/Caches/com.apple.Safari
EOF
note "Anything you added to the PROTECTED list is filtered out and not listed here."
note "Browser PROFILE dirs hold logins/history — review only, never auto-delete."

section "~/Library BIG DIRECTORIES (depth-1, largest first; protected excluded)"
# Use du -d 1 on ~/Library/Caches and ~/Library/Application Support, drop protected, sort desc.
LIB_TMP=$(mktemp 2>/dev/null || printf '/tmp/mc_lib_%s' "$$")
: > "$LIB_TMP"
for base in "${H}/Library/Caches" "${H}/Library/Application Support" "${H}/Library/Containers"; do
  [ -d "$base" ] || continue
  # du -d 1 lists each child once; filter protected paths. `|| true` so an
  # unreadable subdir cannot abort under pipefail.
  { du -d 1 -k "$base" 2>/dev/null || true; } | while IFS=$'\t' read -r kb path; do
    [ "$path" = "$base" ] && continue
    is_protected "$path" && continue
    printf '%s\t%s\n' "$kb" "$path"
  done >> "$LIB_TMP"
done
if [ -s "$LIB_TMP" ]; then
  { sort -t$'\t' -k1,1 -rn "$LIB_TMP" 2>/dev/null || true; } | head -25 | while IFS=$'\t' read -r kb path; do
    human=$(awk -v k="$kb" 'BEGIN{ if(k>=1048576) printf "%.1fG", k/1048576; else if(k>=1024) printf "%.0fM", k/1024; else printf "%dK", k }')
    printf '  %8s   %s%s%s\n' "$human" "$D" "$path" "$R"
  done
else
  note "(no ~/Library subdirectories found)"
fi
rm -f "$LIB_TMP" 2>/dev/null || true
note "All paths in the PROTECTED list are filtered out of this listing."

section "DOWNLOADS — installers / archives / build artifacts (Review)"
if [ -d "${H}/Downloads" ]; then
  sub "Installers & archives at top of ~/Downloads (largest first)"
  out=$( { find "${H}/Downloads" -maxdepth 1 \( -name '*.dmg' -o -name '*.pkg' -o -name '*.zip' -o -name '*.rar' \) \
            -exec du -sh {} \; 2>/dev/null || true; } | sort -rh 2>/dev/null | head -30 )
  if [ -n "$out" ]; then printf '%s\n' "$out"; else note "(none found)"; fi
  sub ".next / node_modules build artifacts inside ~/Downloads projects (largest first)"
  # Find .next and node_modules, prune descent, NUL-safe iteration, exclude protected.
  out=$( { find "${H}/Downloads" -type d \( -name '.next' -o -name 'node_modules' \) -prune -print0 2>/dev/null || true; } \
    | while IFS= read -r -d '' d; do
        is_protected "$d" && continue
        du -sh "$d" 2>/dev/null || true
      done | sort -rh 2>/dev/null | head -20 )
  if [ -n "$out" ]; then printf '%s\n' "$out"; else note "(none found)"; fi
else
  note "~/Downloads not present."
fi

section "STRAY / NOTEWORTHY (Caution — verify before any action)"
# Active virtualenv detection: if your live python3 resolves into a venv UNDER your
# home dir, flag it as the live interpreter (deleting it would break python3).
# Generic — detects whatever venv your python3 actually points to, not a fixed path.
PY3=$(command -v python3 2>/dev/null || true)
if [ -n "$PY3" ]; then
  VENV_PREFIX=$(python3 -c 'import sys;print(sys.prefix)' 2>/dev/null || true)
  case "${VENV_PREFIX:-}" in
    "${H}"/*)
      sub "Active Python virtualenv under your home (Caution — LIVE interpreter)"
      du -sh "$VENV_PREFIX" 2>/dev/null || true
      printf '  active python3 -> %s\n' "$PY3"
      printf '  python3 sys.prefix -> %s\n' "$VENV_PREFIX"
      printf '%s  !! CAUTION: python3 resolves into %s (under your home) — it is your LIVE interpreter.%s\n' "$Y" "$VENV_PREFIX" "$R"
      note "Deleting it breaks the default python3. Only remove if abandoned (see clean.sh)." ;;
  esac
fi
# sleepimage / hibernation file
if [ -e /private/var/vm/sleepimage ]; then
  ls -lah /private/var/vm/sleepimage 2>/dev/null || true
  pmset -g 2>/dev/null | grep -i hibernatemode || true
  note "sleepimage reclaim (~2GB) requires hibernatemode 0 — Caution (sleep data-loss risk). See clean.sh."
fi
# iOS device backups
if [ -d "${H}/Library/Application Support/MobileSync/Backup" ]; then
  sub "iOS device backups (Caution — may be the only copy)"
  out=$( { du -sh "${H}/Library/Application Support/MobileSync/Backup/"*/ 2>/dev/null || true; } | sort -rh 2>/dev/null )
  if [ -n "$out" ]; then printf '%s\n' "$out"; else note "(none)"; fi
fi

section "LARGE FILES > 500MB in home (read-only; protected & user-data excluded)"
# -xdev stays on the home volume. Build the prune expression from the PROTECTED list
# so user-configured protect paths are honored too. All pipes are made tolerant
# (|| true) so a permission-denied file cannot abort under pipefail.
PRUNE_ARGS=()
for p in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
  PRUNE_ARGS+=( -path "$p" -o )
done
out=$( { find "$H" -xdev \( ${PRUNE_ARGS[@]+"${PRUNE_ARGS[@]}"} -false \) -prune -o \
  -type f -size +500M -print0 2>/dev/null || true; } \
  | while IFS= read -r -d '' f; do
      is_protected "$f" && continue
      du -sh "$f" 2>/dev/null || true
    done | sort -rh 2>/dev/null | head -30 )
if [ -n "$out" ]; then printf '%s\n' "$out"; else note "(no files > 500MB found outside protected dirs)"; fi
note "Photos Library and messaging-app containers are USER DATA — never auto-delete (awareness only)."

# ----------------------------------------------------------------------------
# Xcode simulator runtimes (CleanMyMac "Xcode Junk" — biggest dev win when present).
# ----------------------------------------------------------------------------
section "XCODE SIMULATOR RUNTIMES (read-only)"
if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
  RT=$(xcrun simctl runtime list 2>/dev/null || true)
  if [ -n "$RT" ]; then
    printf '%s\n' "$RT" | sed 's/^/  /'
    UNAVAIL=$(printf '%s' "$RT" | grep -ci 'unavailable' || true)
    if [ "${UNAVAIL:-0}" -gt 0 ]; then
      printf '%s  %s unavailable runtime(s) — orphaned by Xcode/OS updates, re-downloadable.%s\n' "$Y" "$UNAVAIL" "$R"
      note "Reclaim (Safe, tool-native): xcrun simctl delete unavailable   (clean.sh offers this)"
    else
      note "No unavailable runtimes — nothing to prune."
    fi
  else
    note "simctl returned no runtimes."
  fi
else
  note "Xcode command-line tools / simctl not present — skipping."
fi

# ----------------------------------------------------------------------------
# User + system logs (CleanMyMac "User/System Log Files").
# ----------------------------------------------------------------------------
section "LOGS — user (read-only). NEVER blanket-wiped; Claude + DiagnosticReports excluded."
if [ -d "${H}/Library/Logs" ]; then
  du -sh "${H}/Library/Logs" 2>/dev/null || true
  sub "Stale third-party log dirs/files >30d (candidates only — excludes Claude & DiagnosticReports)"
  out=$( { find "${H}/Library/Logs" -mindepth 1 -maxdepth 1 -mtime +30 ! -name Claude ! -path '*Claude*' ! -name DiagnosticReports -print0 2>/dev/null || true; } \
    | while IFS= read -r -d '' lg; do is_protected "$lg" && continue; du -sh "$lg" 2>/dev/null || true; done | sort -rh 2>/dev/null | head -20 )
  if [ -n "$out" ]; then printf '%s\n' "$out"; else note "(no stale third-party logs >30d)"; fi
else
  note "~/Library/Logs not present."
fi
note "System logs (/private/var/log) need sudo to clear — handled in the deferred end-of-session sudo block, not here."

# ----------------------------------------------------------------------------
# Broken preferences (CleanMyMac "Broken Preferences") — corrupt plists.
# ----------------------------------------------------------------------------
section "BROKEN PREFERENCES (read-only) — plists that fail plutil -lint"
if command -v plutil >/dev/null 2>&1 && [ -d "${H}/Library/Preferences" ]; then
  bad=0
  while IFS= read -r -d '' plf; do
    is_protected "$plf" && continue
    if ! plutil -lint "$plf" >/dev/null 2>&1; then
      du -sh "$plf" 2>/dev/null || true
      bad=$((bad+1))
    fi
  done < <(find "${H}/Library/Preferences" -maxdepth 1 -type f -name '*.plist' -print0 2>/dev/null)
  [ "$bad" -eq 0 ] && note "(no corrupt plists found — good)" \
    || note "${bad} corrupt plist(s) — safe to remove; owning app regenerates a clean default. (clean.sh offers each)"
else
  note "plutil or ~/Library/Preferences unavailable — skipping."
fi

# ----------------------------------------------------------------------------
# Broken login items (CleanMyMac "Broken Login Items") — agents to missing apps.
# ----------------------------------------------------------------------------
section "BROKEN LOGIN ITEMS (read-only) — user LaunchAgents pointing to a missing program"
broken=0
if [ -d "${H}/Library/LaunchAgents" ]; then
  for pl in "${H}/Library/LaunchAgents/"*.plist; do
    [ -e "$pl" ] || continue
    prog=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$pl" 2>/dev/null || true)
    [ -z "$prog" ] && prog=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$pl" 2>/dev/null || true)
    if [ -n "$prog" ] && [ ! -e "$prog" ]; then
      printf '%s  BROKEN%s %s -> missing: %s\n' "$Y" "$R" "${pl##*/}" "$prog"
      broken=$((broken+1))
    fi
  done
fi
[ "$broken" -eq 0 ] && note "(no broken user LaunchAgents found)" \
  || note "${broken} orphaned agent(s). Remove the plist + check System Settings > Login Items. Verify it's truly unused first."

# ----------------------------------------------------------------------------
# Phase 1d — Optimizations NOT yet applied (read-only checks)
# ----------------------------------------------------------------------------
section "OPTIMIZATIONS — which background/perf tweaks are not yet applied (read-only)"
note "These are background-only. NO UI/visual changes are ever made."

sub "Login items / background items"
if command -v launchctl >/dev/null 2>&1; then
  printf '  Non-Apple loaded launch jobs:\n'
  launchctl list 2>/dev/null | grep -v com.apple | sort | sed 's/^/    /' || note "(none)"
fi
printf '  User LaunchAgents:\n'
ls -1 "${H}/Library/LaunchAgents" 2>/dev/null | sed 's/^/    /' || note "    (none)"
note "Full inventory needs sudo: 'sudo sfltool dumpbtm'. Review before disabling anything."
note "Remove unneeded ones via System Settings > Login Items, or: launchctl bootout gui/\$(id -u)/<label>"

sub "Homebrew background services"
if command -v brew >/dev/null 2>&1; then
  brew services list 2>/dev/null | sed 's/^/  /' || note "  (brew services unavailable)"
else
  note "  brew not installed."
fi

sub "Spotlight indexing status (Data volume should be indexed)"
mdutil -s / 2>/dev/null | sed 's/^/  /' || note "  (mdutil status / unavailable — sudo may be needed)"
mdutil -s /System/Volumes/Data 2>/dev/null | sed 's/^/  /' || true
note "On Tahoe the signed '/' index is read-only — that is NORMAL. Index the Data volume."
note "Highest-leverage permanent fix: exclude node_modules/build dirs in Spotlight Privacy."

sub "Power management (background wakes)"
pmset -g 2>/dev/null | grep -iE 'hibernatemode|powernap|proximitywake|standby ' | sed 's/^/  /' || true
note "Background-only opt-ins (no UI change): 'sudo pmset -a powernap 0' and 'sudo pmset -a proximitywake 0'."
note "Do NOT use lowpowermode (throttles P-cores; affects interactive feel). Leave hibernatemode at 3."

sub "Third-party 'memory cleaner' login agents (net-negative — recommend removal)"
ls -1 "${H}/Library/LaunchAgents" 2>/dev/null | grep -iE 'clean|memory|optimizer' | sed 's/^/  /' \
  || note "  (none found — good)"

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
section "SCAN COMPLETE"
printf '%sNext steps:%s\n' "$B" "$R"
note "Disk cleanup (dry-run by default):   ./scripts/clean.sh            (add --apply to delete)"
note "Safe-only dry-run:                   ./scripts/clean.sh --safe-only"
note "Background/perf optimizations:       ./scripts/optimize.sh         (add --apply to act)"
note "Nothing was deleted, moved, or modified by this scan."
