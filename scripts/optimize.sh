#!/usr/bin/env bash
#
# optimize.sh — background/perf optimization audit for Apple Silicon Macs
#               (M-series, arm64; tuned for 8GB unified RAM).
#
# READ-ONLY AUDIT BY DEFAULT. Without --apply this script only reports state:
# login items, brew services, launch agents, Spotlight status, memory pressure,
# swap, power-management/background wakes. It changes NOTHING.
#
# With --apply it performs ONLY opt-in, NON-UI, background/perf actions, each
# gated behind an explicit per-action confirmation:
#   - flush DNS cache
#   - sudo purge (inactive page flush — low value, opt-in)
#   - disable Power Nap + proximity wake (background-only; reversible)
#   - prompt to bootout a specific reviewed user login item (never an Apple label)
#
# HARD CONSTRAINTS (never violated):
#   - NEVER any UI/visual `defaults write`: no reduce-motion, no animation disabling,
#     no Dock autohide/transparency, no menubar tweaks, no font smoothing. None.
#   - Heavy rebuilds (mdutil -E, atsutil databases -remove, lsregister -kill -r) are
#     symptom-driven only — printed as guidance, NEVER auto-run, even with --apply.
#   - No disk deletions at all; protected user data is never touched.
#   - swap is never disabled; hibernatemode left at 3; lowpowermode never enabled.
#
# USAGE:
#   ./optimize.sh            # read-only audit (default — changes nothing)
#   ./optimize.sh --apply    # perform opt-in actions, each confirmed individually
#   ./optimize.sh --apply --yes
#                            # --yes skips prompts for NON-sudo actions only. Every
#                            # sudo/system change (DNS flush, pmset, purge, bootout)
#                            # ALWAYS prompts for an explicit "yes", even with --yes.
#
# macOS BSD-correct; bash 3.2 + set -u safe (guarded array expansion).
#
set -euo pipefail

APPLY=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

HOME_DIR="${HOME:-}"
if [ -z "${HOME_DIR}" ] || [ ! -d "${HOME_DIR}" ]; then HOME_DIR=$(eval echo "~$(id -un)"); fi
H="$HOME_DIR"

if [ -t 1 ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
  C=$(printf '\033[36m'); Y=$(printf '\033[33m'); G=$(printf '\033[32m')
else
  B=""; D=""; R=""; C=""; Y=""; G=""
fi
section() { printf '\n%s%s== %s ==%s\n' "$B" "$C" "$1" "$R"; }
sub()     { printf '\n%s-- %s --%s\n' "$B" "$1" "$R"; }
note()    { printf '%s  %s%s\n' "$D" "$1" "$R"; }

# confirm <prompt> [sensitive] -> 0 if approved.
# Audit fix: --yes auto-approves ONLY non-sensitive prompts. Any "sensitive"
# action (sudo / system mutation) always requires an explicit "yes" typed in,
# even under --yes — no sudo change ever runs silently.
confirm() {
  if [ "$ASSUME_YES" -eq 1 ] && [ "${2:-}" != "sensitive" ]; then return 0; fi
  printf '%s%s [type yes]: %s' "$B" "$1" "$R"
  local a; read -r a </dev/tty 2>/dev/null || read -r a || a=""
  [ "$a" = "yes" ]
}

printf '%s%s' "$B" "$C"
cat <<'BANNER'
========================================================================
  mac-cleaner :: OPTIMIZE (background/perf only — ZERO UI/visual changes)
BANNER
printf '%s' "$R"
if [ "$APPLY" -eq 1 ]; then
  printf '%s  MODE: APPLY (each action asks for confirmation first)%s\n' "$Y" "$R"
else
  printf '%s  MODE: AUDIT (read-only — nothing is changed)%s\n' "$G" "$R"
fi
printf '%s========================================================================%s\n' "$B" "$R"
note "No UI/animation/Dock/menubar/font defaults are ever written. Background work only."

# ----------------------------------------------------------------------------
# AUDIT (always runs, read-only)
# ----------------------------------------------------------------------------
section "MEMORY PRESSURE & SWAP (read-only)"
memory_pressure 2>/dev/null | grep -iE 'System-wide|free percentage|pressure' || memory_pressure 2>/dev/null || true
SWAP=$(sysctl -n vm.swapusage 2>/dev/null || true)
printf '  swap: %s\n' "${SWAP:-unavailable}"
note "On 8GB, RAM is the bottleneck. The only durable fix is quitting idle apps + trimming login items."
note "sudo purge frees only ~200-600MB and slows subsequent I/O — opt-in, never scheduled."

sub "Top memory consumers (ps aux -m — BSD memory sort)"
ps aux -m 2>/dev/null | head -12 || true
note "To quit an app GRACEFULLY (save work first): osascript -e 'quit app \"AppName\"'"
note "Never kill kernel_task, WindowServer, or loginwindow."

section "LOGIN ITEMS / BACKGROUND ITEMS (read-only)"
sub "Non-Apple loaded launch jobs"
launchctl list 2>/dev/null | grep -v com.apple | sort | sed 's/^/  /' || note "(none)"
sub "User LaunchAgents (~/Library/LaunchAgents)"
ls -1 "${H}/Library/LaunchAgents" 2>/dev/null | sed 's/^/  /' || note "(none)"
note "Full background-item DB (needs sudo): sudo sfltool dumpbtm"
note "Good removal candidates: diagnostic-only helpers and agents for apps you only use in-browser."
note "KEEP anything you actively rely on (key remapper, clipboard manager). Confirm each label before disabling."

sub "Suspicious third-party 'memory cleaner' / 'optimizer' agents (net-negative)"
ls -1 "${H}/Library/LaunchAgents" 2>/dev/null | grep -iE 'clean|memory|optimizer' | sed 's/^/  /' \
  || note "(none found — good; these add idle CPU and do not beat the kernel compressor)"

section "HOMEBREW BACKGROUND SERVICES (read-only)"
if command -v brew >/dev/null 2>&1; then
  brew services list 2>/dev/null | sed 's/^/  /' || note "(unavailable)"
  note "Stop an unneeded one with: brew services stop <name> ; then: brew services cleanup"
else
  note "brew not installed."
fi

section "SPOTLIGHT INDEXING STATUS (read-only)"
mdutil -s / 2>/dev/null | sed 's/^/  /' || note "(mdutil status / needs sudo or is unavailable)"
mdutil -s /System/Volumes/Data 2>/dev/null | sed 's/^/  /' || true
note "On Tahoe the signed '/' index is read-only — NORMAL. The Data volume index is what matters."
note "Highest-leverage permanent fix (no UI change): exclude heavy dev dirs (node_modules, build/)"
note "in System Settings > Spotlight > Search Privacy, or rename a folder to end in .noindex."
note "Do NOT 'mdutil -a -i off' (unreliable on Tahoe Data volume, breaks search)."

section "POWER MANAGEMENT / BACKGROUND WAKES (read-only)"
pmset -g 2>/dev/null | grep -iE 'hibernatemode|powernap|proximitywake|standby ' | sed 's/^/  /' || true
sub "Active power assertions (what is preventing sleep)"
pmset -g assertions 2>/dev/null | grep -iE 'PreventUserIdleSystemSleep|PreventSystemSleep|created' | head -12 | sed 's/^/  /' || true
note "Opt-in background-only tweaks (no UI change, reversible): disable Power Nap + proximity wake."

section "DNS RESOLVER"
note "No read-only size. Flushing fixes stale-DNS network hangs (opt-in action below)."

section "SYMPTOM-DRIVEN REBUILDS (NEVER auto-run — guidance only)"
note "These cause CPU/RAM/IO storms on 8GB. Run only if you actually see the symptom, then reboot."
note "Font cache (only if fontd/ATSServer spikes at login): quit all apps, then"
note "  sudo atsutil databases -remove && atsutil server -shutdown   # then reboot"
note "LaunchServices (only if 'Open With' shows duplicates):"
note "  .../LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"
note "Spotlight full reindex (only if mds stuck >2h): sudo mdutil -E /System/Volumes/Data  (will hammer the machine)"

# ----------------------------------------------------------------------------
# APPLY (opt-in, per-action confirmation). No UI changes ever.
# ----------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  section "AUDIT COMPLETE"
  note "Nothing was changed. Re-run with --apply to perform opt-in background/perf actions."
  exit 0
fi

section "APPLY — opt-in actions (each confirmed individually)"

cat <<'PLAN'
  The following opt-in actions MAY run. Each asks for an explicit "yes" first —
  every sudo action prompts even with --yes. Nothing runs without your approval:
    1. Flush DNS cache                     (sudo dscacheutil -flushcache; killall -HUP mDNSResponder)
    2. Disable Power Nap + proximity wake  (sudo pmset -a powernap 0; proximitywake 0)  [reversible]
    3. sudo purge                          (flush inactive pages — low value on Apple Silicon)
    4. Bootout one reviewed user login item (never an Apple label)
  None of these change any UI/visual setting.
PLAN

# 1) Flush DNS cache (safe, transient).
if confirm "Flush DNS cache (sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder)?" sensitive; then
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder && printf '%s  DNS cache flushed (no output = success).%s\n' "$G" "$R" || \
    printf '%s  DNS flush returned non-zero.%s\n' "$Y" "$R"
else
  note "Skipped DNS flush."
fi

# 2) Disable Power Nap + proximity wake (background-only, reversible).
if confirm "Disable Power Nap + proximity wake (sudo pmset -a powernap 0; proximitywake 0)? Reversible with value 1." sensitive; then
  sudo pmset -a powernap 0 || printf '%s  powernap set returned non-zero.%s\n' "$Y" "$R"
  sudo pmset -a proximitywake 0 || printf '%s  proximitywake set returned non-zero.%s\n' "$Y" "$R"
  printf '%s  Done. Tradeoff: less background Mail/iCloud sync while the lid is closed.%s\n' "$G" "$R"
  note "Revert anytime: sudo pmset -a powernap 1; sudo pmset -a proximitywake 1"
else
  note "Skipped power-management tweak."
fi

# 3) sudo purge (low value, opt-in).
if confirm "Run 'sudo purge' (flush inactive pages)? Low value on Apple Silicon; briefly slows I/O as caches re-warm." sensitive; then
  sudo purge && printf '%s  purge done (transient relief only — quitting apps frees far more).%s\n' "$G" "$R" || \
    printf '%s  purge returned non-zero.%s\n' "$Y" "$R"
else
  note "Skipped purge."
fi

# 4) Bootout a specific reviewed user login item (never Apple labels).
section "Disable a specific user login item (optional)"
note "Loaded non-Apple user agents:"
launchctl list 2>/dev/null | grep -v com.apple | awk 'NR>1{print "   "$3}' | sort -u || true
printf '%sEnter a label to bootout (e.g. a reviewed agent), or press Enter to skip: %s' "$B" "$R"
LABEL=""
if [ "$ASSUME_YES" -ne 1 ]; then read -r LABEL || LABEL=""; fi
if [ -n "$LABEL" ]; then
  case "$LABEL" in
    com.apple.*)
      printf '%s  Refusing to bootout an Apple label (%s). Apple services are off-limits.%s\n' "$Y" "$LABEL" "$R" ;;
    *)
      printf '%s  Inspecting %s first:%s\n' "$D" "$LABEL" "$R"
      launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | head -8 | sed 's/^/    /' || note "    (label not currently loaded — nothing to bootout)"
      if confirm "Bootout gui/$(id -u)/${LABEL} for this session (it stays loaded next login unless removed in Login Items)?" sensitive; then
        launchctl bootout "gui/$(id -u)/${LABEL}" && printf '%s  Booted out %s.%s\n' "$G" "$LABEL" "$R" || \
          printf '%s  bootout returned non-zero (wrong label?).%s\n' "$Y" "$R"
        note "To remove it permanently: System Settings > General > Login Items & Extensions."
      else
        note "Skipped bootout."
      fi
      ;;
  esac
else
  note "No login item disabled."
fi

section "OPTIMIZE COMPLETE"
note "Only background/perf items were touched. No UI/visual setting was changed."
note "Biggest remaining lever on 8GB: quit idle Electron/Chromium apps, then re-check swap."
