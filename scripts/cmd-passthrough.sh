#!/usr/bin/env bash
# scripts/cmd-passthrough.sh — backs /trai:passthrough.
# Sets a one-shot bypass token the PreToolUse hook consumes on the next Bash call.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  echo "trai: no active session (nothing to bypass)."
  exit 0
fi

mkdir -p "$TRAI_STATE_ROOT"
: > "$TRAI_BYPASS"
echo "trai: next Bash command will bypass the try sandbox (one-shot)."
echo "            if Claude does not run a Bash command next, the token remains until one does."
