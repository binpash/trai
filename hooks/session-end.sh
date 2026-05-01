#!/usr/bin/env bash
# hooks/session-end.sh — fires when a Claude session ends.
# If the overlay is non-empty, prints a banner reminding the user to commit or discard.
# Never auto-commits or auto-discards.

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" || ! -d "$overlay" ]]; then
  exit 0
fi

# Ask `try summary` whether there is anything to review. It's noisy on stderr
# (mount warnings) but prints a clean list on stdout; we only care if any
# change-type lines appear (added, modified, deleted, created dir, symlink, …).
try_bin="$(trai::try_bin || true)"
if [[ -z "$try_bin" ]]; then
  exit 0
fi
summary="$("$try_bin" summary "$overlay" 2>/dev/null || true)"
count="$(printf '%s\n' "$summary" | grep -cE '\([a-z][a-z ]*\)$' || true)"

if [[ "${count:-0}" -eq 0 ]]; then
  exit 0
fi

size="$(du -sh "$overlay" 2>/dev/null | awk '{print $1}' || true)"
[[ -z "$size" ]] && size="unknown"

msg="trai: session ended with an uncommitted overlay.
  overlay: $overlay
  files changed: $count
  size: $size
  next: start a new Claude session and run /trai:diff, then /trai:commit or /trai:discard --yes
  (overlay persists on disk until you act on it)"

jq -n --arg msg "$msg" '{systemMessage: $msg}'
