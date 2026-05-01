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

# The overlayfs workdir/work directory is created with d--------- permissions
# by the kernel. chmod u+w alone isn't enough — rm -rf also needs +x to descend.
chmod -R u+rwx "$session_dir" 2>/dev/null || true
rm -rf "$session_dir" 2>/dev/null || true

if [[ -d "$session_dir" ]]; then
  echo "trai: could not fully remove $session_dir (permission-denied dirs remain)."
  echo "            Retry with:   sudo rm -rf \"$session_dir\""
  trai::clear_session
  exit 1
fi

trai::clear_session
echo "trai: discarded. Session cleared."
