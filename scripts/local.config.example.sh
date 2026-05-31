#!/usr/bin/env bash
#
# local.config.example.sh — personal, machine-local settings template.
#
# Copy this to local.config.sh and edit it. `local.config.sh` is git-ignored, so
# your personal settings are NEVER committed or published:
#
#     cp scripts/local.config.example.sh scripts/local.config.sh
#
# scan.sh and clean.sh source local.config.sh (if present) at startup and merge
# whatever you set here. Nothing here affects the public repo.

# ----------------------------------------------------------------------------
# PROTECT_EXTRA — extra paths to ALWAYS protect.
# These are added to the built-in protect list (~/.claude). They are never
# scanned as deletable, never cleaned, and excluded from the large-file sweep.
# Add browser profiles, password-manager vaults, active working dirs, etc.
# ----------------------------------------------------------------------------
PROTECT_EXTRA=(
  # "$HOME/Library/Application Support/Arc"
  # "$HOME/Library/Caches/Arc"
  # "$HOME/Library/Application Support/SomeApp"
  # "$HOME/work/important-project"
)
