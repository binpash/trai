#!/usr/bin/env bash
# scripts/cmd-diff.sh — backs /trai:diff.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  echo "trai: no active session. Nothing to diff."
  exit 0
fi

try_bin="$(trai::try_bin)" || {
  echo "trai: try binary not found; cannot run summary."
  exit 1
}

# Run try summary, filter state-file noise, print.
# try summary writes some warnings to stderr; we suppress those here.
summary="$("$try_bin" summary "$overlay" 2>/dev/null || true)"

if [[ -z "$summary" || "$(printf '%s\n' "$summary" | grep -cE '\((added|modified|deleted)\)' || true)" -eq 0 ]]; then
  echo "trai: no filesystem changes in the current overlay."
  exit 0
fi

filtered="$(printf '%s\n' "$summary" | "$CLAUDE_PLUGIN_ROOT/scripts/filter-ignored.sh")"

if [[ "$(printf '%s\n' "$filtered" | grep -cE '\((added|modified|deleted)\)' || true)" -eq 0 ]]; then
  echo "trai: no user-relevant filesystem changes (all changes are in ignored paths)."
  exit 0
fi

printf '%s\n' "$filtered"
