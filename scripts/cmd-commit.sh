#!/usr/bin/env bash
# scripts/cmd-commit.sh — backs /trai:commit. DESTRUCTIVE.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  echo "trai: no active session. Nothing to commit."
  exit 0
fi

try_bin="$(trai::try_bin)" || {
  echo "trai: try binary not found; cannot commit."
  exit 1
}

count="$("$try_bin" summary "$overlay" 2>/dev/null | grep -cE '\((added|modified|deleted)\)' || true)"
if [[ "${count:-0}" -eq 0 ]]; then
  echo "trai: overlay is empty; nothing to commit. Session remains active."
  exit 0
fi

echo "trai: committing $count change(s) from $overlay to the real filesystem..."
"$try_bin" commit "$overlay"

echo "trai: commit complete. Clearing session."
trai::clear_session
# Remove the now-applied overlay; best-effort.
rm -rf "$(dirname "$overlay")" 2>/dev/null || true

echo "trai: done. If anything looks wrong, recover via git."

# Immediately start a fresh overlay so subsequent Bash commands stay sandboxed.
new_overlay="$(trai::new_session)"
meta="$(dirname "$new_overlay")/meta.json"
git_head=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git_head="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo '')"
fi
jq -n \
  --arg overlay "$new_overlay" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cwd "${CLAUDE_PROJECT_DIR:-$PWD}" \
  --arg git_head "$git_head" \
  '{overlay: $overlay, started: $started, cwd: $cwd, git_head: $git_head}' \
  > "$meta"
echo "trai: new sandbox started at $new_overlay"
