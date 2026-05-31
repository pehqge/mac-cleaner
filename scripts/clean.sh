#!/usr/bin/env bash
#
# clean.sh — disk cleanup for Apple Silicon Macs (M-series, arm64).
#
# DRY-RUN BY DEFAULT. Without --apply this script DELETES NOTHING. It prints exactly
# what WOULD be removed, per item, with the reclaimable size, grouped Safe / Review /
# Caution and sorted largest-first. You must pass --apply to actually delete, and even
# then a summary is printed and explicit confirmation is required before anything runs.
#
# USAGE:
#   ./clean.sh                      # dry-run, all categories (Safe + Review), preview only
#   ./clean.sh --safe-only          # dry-run, Safe category only
#   ./clean.sh --apply              # apply, with summary + confirmation
#   ./clean.sh --safe-only --apply  # apply only Safe items, with confirmation
#   ./clean.sh --include-downloads  # also consider Downloads build artifacts (.next) — off by default
#   ./clean.sh --ignore <dir>       # exclude a dir (repeatable)
#   ./clean.sh --yes                # skip the interactive confirm (still prints summary). Use with care.
#
# HARD CONSTRAINTS (never violated):
#   - Every path in the PROTECTED list is excluded from every operation (~/.claude by
#     default; add your own browser/vault/working dirs there or via --ignore).
#   - An active virtualenv your python3 resolves into is BLOCKED by default (deleting it
#     breaks your live interpreter). Not deletable here.
#   - ~/Library/Logs is NEVER blanket-wiped; only stale non-Claude third-party logs, per review.
#   - Caution items (sleepimage, iOS backups, Docker --volumes) are NOT run by this script's
#     batch; they are documented with their exact gated commands for manual, explicit execution.
#   - No UI/visual changes anywhere.
#
# macOS BSD-correct: du -sh/-sk (no -b), stat -f, sort -rh, find -size M/G, NUL-safe loops.
# bash 3.2 + set -u safe: all array expansions guarded with ${arr[@]+"${arr[@]}"}.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Flags
# ----------------------------------------------------------------------------
APPLY=0
SAFE_ONLY=0
INCLUDE_DOWNLOADS=0
ASSUME_YES=0
IGNORES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)             APPLY=1 ;;
    --safe-only)         SAFE_ONLY=1 ;;
    --include-downloads) INCLUDE_DOWNLOADS=1 ;;
    --yes|-y)            ASSUME_YES=1 ;;
    --ignore)            shift; [ $# -gt 0 ] || { echo "--ignore needs a path" >&2; exit 2; }; IGNORES+=("$1") ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Try --help." >&2; exit 2 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
HOME_DIR="${HOME:-}"
if [ -z "${HOME_DIR}" ] || [ ! -d "${HOME_DIR}" ]; then
  HOME_DIR=$(eval echo "~$(id -un)")
fi
H="$HOME_DIR"

# Protected — never operated on. ~/.claude by default; add your own (browser profile,
# vault, working dir) here or via --ignore. An active venv is handled separately (Caution).
PROTECTED=(
  "${H}/.claude"
  # Examples — uncomment / edit to protect your own data:
  # "${H}/Library/Application Support/Arc"
  # "${H}/Library/Caches/Arc"
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
# Append user --ignore dirs to the protected set.
for ig in ${IGNORES[@]+"${IGNORES[@]}"}; do
  case "$ig" in /*) PROTECTED+=("$ig") ;; *) PROTECTED+=("${H}/${ig#./}") ;; esac
done

if [ -t 1 ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
  Y=$(printf '\033[33m'); G=$(printf '\033[32m'); RED=$(printf '\033[31m')
else
  B=""; D=""; R=""; Y=""; G=""; RED=""
fi

is_protected() {
  local t="$1" p
  for p in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
    case "$t" in "$p"|"$p"/*) return 0 ;; esac
  done
  return 1
}

# Human-readable size of a path (empty if missing/protected).
# `|| true` so a permission-denied du never aborts under set -e + pipefail.
human_size() {
  local p="$1"
  [ -e "$p" ] || return 0
  is_protected "$p" && return 0
  { du -sh "$p" 2>/dev/null || true; } | awk '{print $1; exit}'
}
kib_size() {
  local p="$1"
  [ -e "$p" ] || { printf '0'; return; }
  is_protected "$p" && { printf '0'; return; }
  local v
  v=$( { du -sk "$p" 2>/dev/null || true; } | awk '{print $1; exit}' )
  printf '%s' "${v:-0}"
}

# Accumulators (parallel arrays — bash 3.2 has no associative arrays portably).
PLAN_GROUP=()   # safe|review
PLAN_LABEL=()
PLAN_KB=()
PLAN_HUMAN=()
PLAN_CMD=()     # the exact command string that --apply would run
PLAN_KIND=()    # rmtree | rmglob | tool

TOTAL_SAFE_KB=0
TOTAL_REVIEW_KB=0

# add_item <group> <label> <kib> <human> <kind> <command>
add_item() {
  PLAN_GROUP+=("$1"); PLAN_LABEL+=("$2"); PLAN_KB+=("$3"); PLAN_HUMAN+=("$4"); PLAN_KIND+=("$5"); PLAN_CMD+=("$6")
  if [ "$1" = "safe" ]; then TOTAL_SAFE_KB=$((TOTAL_SAFE_KB + ${3:-0})); else TOTAL_REVIEW_KB=$((TOTAL_REVIEW_KB + ${3:-0})); fi
}

kb_to_human() {
  awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.1fG", k/1048576; else if(k>=1024) printf "%.0fM", k/1024; else printf "%dK", k }'
}

# ----------------------------------------------------------------------------
# Build the plan (read-only sizing). Nothing is executed in this phase.
# ----------------------------------------------------------------------------

# --- SAFE: pnpm store prune (tool-native; only removes unreferenced packages) ---
if command -v pnpm >/dev/null 2>&1; then
  PNPM_STORE=$(pnpm store path 2>/dev/null || true)
  [ -z "$PNPM_STORE" ] && PNPM_STORE="${H}/Library/pnpm/store"
  if [ -d "$PNPM_STORE" ] && ! is_protected "$PNPM_STORE"; then
    kb=$(kib_size "$PNPM_STORE"); hu=$(kb_to_human "$kb")
    add_item safe "pnpm store prune (unreferenced pkgs only)" "$kb" "store=$hu" tool "pnpm store prune"
  fi
fi

# --- SAFE: npm _npx one-off cache (pure junk; never rm all of ~/.npm) ---
if [ -d "${H}/.npm/_npx" ] && ! is_protected "${H}/.npm/_npx"; then
  kb=$(kib_size "${H}/.npm/_npx"); hu=$(kb_to_human "$kb")
  add_item safe "npm _npx one-off cache" "$kb" "$hu" rmtree "rm -rf \"${H}/.npm/_npx\""
fi

# --- SAFE: Google Updater crx_cache (quoted path, glob contents only) ---
GUP="${H}/Library/Application Support/Google/GoogleUpdater/crx_cache"
if [ -d "$GUP" ] && ! is_protected "$GUP"; then
  kb=$(kib_size "$GUP"); hu=$(kb_to_human "$kb")
  # Audit fix: quote the whole path, delete contents (not the dir), so GoogleUpdater re-creates it.
  add_item safe "Google Updater crx_cache contents" "$kb" "$hu" rmglob "rm -rf \"${GUP}\"/*"
fi

# --- SAFE: uv cache (tool-native; never touch ~/.local/share/uv which holds toolchains) ---
if command -v uv >/dev/null 2>&1; then
  UVC="${H}/.cache/uv"
  if [ -d "$UVC" ] && ! is_protected "$UVC"; then
    kb=$(kib_size "$UVC"); hu=$(kb_to_human "$kb")
    add_item safe "uv cache clean (regenerable)" "$kb" "$hu" tool "uv cache clean"
  fi
fi

# --- SAFE: Homebrew — split, dry-run autoremove first (audit fix: no && chain) ---
if command -v brew >/dev/null 2>&1; then
  BC=$(brew --cache 2>/dev/null || true)
  bc_kb=0; bc_hu="?"
  if [ -n "$BC" ] && [ -d "$BC" ]; then bc_kb=$(kib_size "$BC"); bc_hu=$(kb_to_human "$bc_kb"); fi
  add_item safe "Homebrew cleanup -s --prune=0 (stale downloads + old versions)" "$bc_kb" "cache=$bc_hu" tool "brew cleanup -s --prune=0"
  # autoremove is split out and gated separately (medium-risk per audit): preview only here.
  add_item review "Homebrew autoremove (preview first, then approve)" "0" "varies" tool "brew autoremove -n"
fi

# --- REVIEW: duplicate Rust toolchains (keep active/default; only offer non-default) ---
if command -v rustup >/dev/null 2>&1; then
  # Keep BOTH the cwd-active toolchain AND the configured default. Audit fix:
  # `rustup show active-toolchain` is cwd-sensitive (honors directory overrides /
  # rust-toolchain files), so relying on it alone could offer the user's real
  # default for removal when clean.sh is run from inside a pinned project. The
  # keep-set is the union of the configured default and the cwd-active toolchain.
  KEEP_ACTIVE=$( { rustup show active-toolchain 2>/dev/null || true; } | awk '{print $1; exit}')
  KEEP_DEFAULT=$( { rustup default 2>/dev/null || true; } | awk '{print $1; exit}')
  while IFS= read -r tc; do
    [ -n "$tc" ] || continue
    name=$(printf '%s' "$tc" | awk '{print $1}')   # strip "(default)" etc.
    [ -n "$KEEP_ACTIVE" ] && [ "$name" = "$KEEP_ACTIVE" ] && continue
    [ -n "$KEEP_DEFAULT" ] && [ "$name" = "$KEEP_DEFAULT" ] && continue
    tdir="${H}/.rustup/toolchains/${name}"
    [ -d "$tdir" ] || continue
    is_protected "$tdir" && continue
    # Audit fix: project pins reference the CHANNEL/version (e.g. "1.94.0" or
    # "stable"), NOT the full target triple — grep for the channel prefix, not
    # $name, otherwise the pin-detection net is inert and never matches.
    chan=${name%%-*}
    PIN=""
    for proot in "${H}/Downloads" "${H}/Documents" "${H}/Developer" "${H}/src" "${H}/code" "${H}/projects" "${H}/work" "${H}/repos"; do
      [ -d "$proot" ] || continue
      is_protected "$proot" && continue
      hit=$( { grep -rIl --include='rust-toolchain*' "$chan" "$proot" 2>/dev/null || true; } | head -1 )
      if [ -n "$hit" ]; then PIN="$hit"; break; fi
    done
    if [ -n "$PIN" ]; then
      note_pin=" (PINNED by ${PIN} — review before removing)"
    else
      note_pin=""
    fi
    kb=$(kib_size "$tdir"); hu=$(kb_to_human "$kb")
    add_item review "Rust toolchain ${name}${note_pin}" "$kb" "$hu" tool "rustup toolchain uninstall ${name}"
  done <<EOF
$(rustup toolchain list 2>/dev/null)
EOF
fi

# --- REVIEW: Cargo registry/git caches (tool-native preferred; rm -rf as fallback) ---
for cdir in "${H}/.cargo/registry/cache" "${H}/.cargo/registry/src" "${H}/.cargo/git/checkouts" "${H}/.cargo/git/db"; do
  [ -d "$cdir" ] || continue
  is_protected "$cdir" && continue
  kb=$(kib_size "$cdir"); hu=$(kb_to_human "$kb")
  add_item review "Cargo cache: ${cdir#$H/}" "$kb" "$hu" rmtree "rm -rf \"$cdir\""
done

# --- REVIEW: .next build artifacts in Downloads (ONLY with --include-downloads) ---
if [ "$INCLUDE_DOWNLOADS" -eq 1 ] && [ -d "${H}/Downloads" ]; then
  while IFS= read -r -d '' nx; do
    is_protected "$nx" && continue
    kb=$(kib_size "$nx"); hu=$(kb_to_human "$kb")
    # Audit fix: warn to confirm no `next dev` is running against this dir before deleting.
    add_item review ".next build cache (confirm no dev server): ${nx#$H/}" "$kb" "$hu" rmtree "rm -rf \"$nx\""
  done < <(find "${H}/Downloads" -type d -name '.next' -prune -print0 2>/dev/null)
fi

# ----------------------------------------------------------------------------
# Print the plan (always — this is the summary-first requirement).
# ----------------------------------------------------------------------------
printf '%s%s' "$B" "$G"
cat <<'BANNER'
========================================================================
  mac-cleaner :: CLEAN
BANNER
printf '%s' "$R"
if [ "$APPLY" -eq 1 ]; then
  printf '%s  MODE: APPLY (will delete after confirmation)%s\n' "$Y" "$R"
else
  printf '%s  MODE: DRY-RUN (preview only — nothing will be deleted)%s\n' "$G" "$R"
fi
[ "$SAFE_ONLY" -eq 1 ] && printf '  Scope: SAFE items only\n'
[ "$INCLUDE_DOWNLOADS" -eq 1 ] && printf '  Downloads build artifacts: INCLUDED\n' || printf '  Downloads build artifacts: excluded (use --include-downloads)\n'
printf '%s========================================================================%s\n' "$B" "$R"
printf '  Protected (never touched): %s\n' "${PROTECTED[*]+"${PROTECTED[*]}"}"
for ig in ${IGNORES[@]+"${IGNORES[@]}"}; do printf '  Also ignored: %s\n' "$ig"; done

# Helper: print one group, sorted largest-first, return the printed item indices.
print_group() {
  local want="$1" title="$2"
  printf '\n%s== %s ==%s\n' "$B" "$title" "$R"
  # Build sortable lines: "<kb>\t<index>"
  local n=${#PLAN_GROUP[@]} i
  local tmp; tmp=$(mktemp 2>/dev/null || printf '/tmp/mc_clean_%s' "$$"); : > "$tmp"
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${PLAN_GROUP[$i]}" = "$want" ]; then
      printf '%s\t%s\n' "${PLAN_KB[$i]}" "$i" >> "$tmp"
    fi
    i=$((i+1))
  done
  if [ ! -s "$tmp" ]; then
    printf '  %s(nothing found)%s\n' "$D" "$R"; rm -f "$tmp"; return 0
  fi
  sort -t$'\t' -k1,1 -rn "$tmp" | while IFS=$'\t' read -r kb idx; do
    printf '  %s%-9s%s  %s\n' "$B" "${PLAN_HUMAN[$idx]}" "$R" "${PLAN_LABEL[$idx]}"
    printf '            %s$ %s%s\n' "$D" "${PLAN_CMD[$idx]}" "$R"
  done
  rm -f "$tmp"
}

print_group safe "SAFE — regenerable caches & junk"
if [ "$SAFE_ONLY" -eq 0 ]; then
  print_group review "REVIEW — verify before deleting"
fi

# Caution block is documentation-only — never executed by this script's batch.
printf '\n%s== CAUTION — NOT run by this script (manual, explicit, gated) ==%s\n' "$B" "$R"
cat <<CAUTION
  These have real data-loss / rebuild tradeoffs. Run them yourself, one at a time,
  only after the stated check passes. clean.sh will NOT execute them.

  Active Python virtualenv your python3 lives in — BLOCKED by default.
    Detect: python3 -c 'import sys;print(sys.prefix)'   (if it points under your home, it is LIVE)
    Before deleting: <venv>/bin/pip freeze > ~/requirements-backup.txt
                     remove <venv> from PATH/shell rc, verify 'which python3' no longer points there,
                     THEN: rm -rf <venv>
    Breaks your default interpreter until you recreate a venv.

  sleepimage / hibernation (~2.0G) — sleep data-loss risk.
    Default: LEAVE hibernatemode at 3. Opt-in only:
      sudo pmset -a hibernatemode 0 && sudo rm -f /private/var/vm/sleepimage
    Risk: a fully-drained battery during sleep loses unsaved work.

  Docker reclaim — daemon must be running; --volumes can destroy dev DB volumes.
    Review first: docker system df ; docker volume ls
    Safe-ish:     docker system prune -a            (NO --volumes by default)
    buildx cache: docker buildx prune -f
    Only add --volumes after confirming no dev-data volumes matter.
    Note: Docker.raw sparse file does not shrink without 'Reset to factory' or uninstall.

  iOS device backups — may be the only copy of Health/Keychain/encrypted data.
    Identify per-UUID device+date first; confirm another current backup exists, THEN:
      rm -rf "~/Library/Application Support/MobileSync/Backup/<UUID>"

  ~/Library/Logs — NEVER blanket-wiped (contains Claude logs + DiagnosticReports).
    Preview stale third-party logs only:
      find ~/Library/Logs -mindepth 1 -maxdepth 1 -mtime +30 ! -name Claude ! -path '*Claude*' -print
    Remove individually after review.
CAUTION

# Totals
printf '\n%s== ESTIMATED RECLAIM ==%s\n' "$B" "$R"
printf '  Safe   : ~%s\n' "$(kb_to_human "$TOTAL_SAFE_KB")"
if [ "$SAFE_ONLY" -eq 0 ]; then
  printf '  Review : ~%s (after you confirm each is stale)\n' "$(kb_to_human "$TOTAL_REVIEW_KB")"
  printf '  %sTotal  : ~%s%s\n' "$B" "$(kb_to_human "$((TOTAL_SAFE_KB + TOTAL_REVIEW_KB))")" "$R"
fi
printf '  %sNote: pnpm/brew/uv are tool-native prunes — actual freed bytes are typically less than the%s\n' "$D" "$R"
printf '  %sfull cache size shown (they only remove unreferenced/stale entries).%s\n' "$D" "$R"

# ----------------------------------------------------------------------------
# Execute (only with --apply, only after confirmation).
# ----------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  printf '\n%sDRY-RUN complete. Nothing was deleted.%s Re-run with --apply to act.\n' "$G" "$R"
  exit 0
fi

# Collect the indices we will run, honoring --safe-only.
RUN_IDX=()
n=${#PLAN_GROUP[@]}; i=0
while [ "$i" -lt "$n" ]; do
  g="${PLAN_GROUP[$i]}"
  if [ "$g" = "safe" ] || { [ "$SAFE_ONLY" -eq 0 ] && [ "$g" = "review" ]; }; then
    # Skip the brew autoremove -n preview as an "action" — it's only a preview; run it but it deletes nothing.
    RUN_IDX+=("$i")
  fi
  i=$((i+1))
done

if [ "${#RUN_IDX[@]}" -eq 0 ]; then
  printf '\n%sNothing to apply.%s\n' "$Y" "$R"; exit 0
fi

printf '\n%s%sThe following %d commands WILL run:%s\n' "$B" "$Y" "${#RUN_IDX[@]}" "$R"
for idx in ${RUN_IDX[@]+"${RUN_IDX[@]}"}; do
  printf '  $ %s\n' "${PLAN_CMD[$idx]}"
done
if [ "$SAFE_ONLY" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
  printf '  %s(Safe items run as a batch; each Review item is confirmed individually below.)%s\n' "$D" "$R"
fi

# Capture before-state.
BEFORE=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\n%sType EXACTLY "apply" to proceed, anything else to abort: %s' "$B" "$R"
  read -r CONFIRM || CONFIRM=""
  if [ "$CONFIRM" != "apply" ]; then
    printf '%sAborted. Nothing was deleted.%s\n' "$Y" "$R"; exit 1
  fi
fi

printf '\n%sExecuting...%s\n' "$B" "$R"
for idx in ${RUN_IDX[@]+"${RUN_IDX[@]}"}; do
  cmd="${PLAN_CMD[$idx]}"
  printf '  $ %s\n' "$cmd"
  # Safety re-check for rm-based items: never let a protected path through.
  # Derive the guard from the PROTECTED list (full absolute paths) so it honors the
  # user's configured protect dirs, and so it won't false-block a legitimate target
  # like ~/Downloads/Archive/.next (matching is anchored to full configured paths).
  case "${PLAN_KIND[$idx]}" in
    rmtree|rmglob)
      for _pp in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
        case "$cmd" in
          *"$_pp"*) printf '%s    SKIPPED — refuses to touch a protected path (%s).%s\n' "$RED" "$_pp" "$R"; continue 2 ;;
        esac
      done
      ;;
  esac
  # Per-item verification for REVIEW items (audit fix: "verify before deleting"
  # must be enforced in the apply path, not collapsed into the single batch token).
  if [ "${PLAN_GROUP[$idx]}" = "review" ] && [ "$ASSUME_YES" -ne 1 ]; then
    printf '%s    Review item — delete this one? [y/N] %s' "$Y" "$R"
    read -r yn </dev/tty 2>/dev/null || yn=""
    case "$yn" in
      [yY]|[yY][eE][sS]) ;;
      *) printf '%s    skipped.%s\n' "$D" "$R"; continue ;;
    esac
  fi
  # Run; do not abort the whole batch on a single failure.
  if eval "$cmd"; then
    printf '%s    ok%s\n' "$G" "$R"
  else
    printf '%s    command exited non-zero (continuing)%s\n' "$Y" "$R"
  fi
done

AFTER=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${BEFORE:-}" ] && [ -n "${AFTER:-}" ]; then
  DELTA=$(( (AFTER - BEFORE) ))
  printf '\n%sFree space delta:%s %s reclaimed (df -k avail: %s -> %s KiB).\n' \
    "$B" "$R" "$(kb_to_human "$DELTA")" "$BEFORE" "$AFTER"
  printf '  %s(APFS purgeable accounting may make this differ from per-item sizes.)%s\n' "$D" "$R"
fi
printf '%sDone.%s\n' "$G" "$R"
