#!/usr/bin/env bash
# hooks/session-start.sh — fires once when a Claude session begins.
# Creates a fresh overlay dir, records it as $TRAI_CURRENT, and runs doctor
# in quiet mode. If doctor fails, self-disables the plugin for this session by
# clearing the current-session pointer.

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

mkdir -p "$CLAUDE_PLUGIN_DATA" "$TRAI_STATE_ROOT" "$TRAI_SESSIONS_DIR"

# Single-session lock
mkdir -p "$(dirname "$TRAI_LOCK")"
exec 9>"$TRAI_LOCK"
if ! flock -n 9; then
  trai::clear_session
  jq -n '{
    systemMessage: "trai: another Claude session already holds the trai lock. This session will run without Bash sandboxing. Finish or discard the other session first."
  }'
  exit 0
fi

# SessionStart fires on startup AND on /clear, /compact, /resume, auto-compact.
# If a session is already active from an earlier fire, reuse it so commands
# issued across compactions continue landing in the same overlay instead of
# orphaning it.
existing="$(trai::current_overlay)"
if [[ -n "$existing" && -d "$existing" ]]; then
  jq -n --arg overlay "$existing" '{
    systemMessage: ("trai active (resumed). Overlay: " + $overlay + ". Use /trai:diff to review.")
  }'
  exit 0
fi

# Preflight. If doctor fails, the plugin self-disables for this session.
if ! "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" --quiet; then
  trai::clear_session
  jq -n '{
    systemMessage: "trai: preflight failed. Bash sandboxing is disabled for this session. Run /trai:doctor to see what to fix."
  }'
  exit 0
fi

# Create overlay dir and write the current-session pointer
overlay="$(trai::new_session)"

# Capture a small meta.json for /trai:status and /trai:diff
meta="$(dirname "$overlay")/meta.json"
git_head=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git_head="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo '')"
fi
jq -n \
  --arg overlay "$overlay" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cwd "${CLAUDE_PROJECT_DIR:-$PWD}" \
  --arg git_head "$git_head" \
  '{overlay: $overlay, started: $started, cwd: $cwd, git_head: $git_head}' \
  > "$meta"

jq -n --arg overlay "$overlay" '{
  systemMessage: ("trai active. Bash commands are being sandboxed into " + $overlay + ". Use /trai:diff to review, /trai:commit or /trai:discard at end.")
}'
