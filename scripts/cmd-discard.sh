#!/usr/bin/env bash
# scripts/cmd-discard.sh — backs /trai:discard. Requires --yes.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

arg="${1:-}"
if [[ "$arg" != "--yes" ]]; then
  echo "trai: /trai:discard requires the --yes argument to confirm."
  echo "            usage: /trai:discard --yes"
  exit 1
fi

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  echo "trai: no active session. Nothing to discard."
  exit 0
fi

session_dir="$(dirname "$overlay")"
echo "trai: discarding overlay at $session_dir ..."

# Overlay's workdir may have UID-0-inside-userns-owned files that the invoking
# user can't remove directly. chmod first; then rm -rf.
chmod -R u+w "$session_dir" 2>/dev/null || true
rm -rf "$session_dir" 2>/dev/null || true

if [[ -d "$session_dir" ]]; then
  echo "trai: could not fully remove $session_dir (permission-denied dirs remain)."
  echo "            Retry with:   sudo rm -rf \"$session_dir\""
  trai::clear_session
  exit 1
fi

trai::clear_session
echo "trai: discarded. Session cleared."
