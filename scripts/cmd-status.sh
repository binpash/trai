#!/usr/bin/env bash
# scripts/cmd-status.sh — backs /trai:status.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  cat <<EOF
trai: no active session.

Likely causes (most to least common):
  - SessionStart hook hasn't fired yet in this Claude session.
  - Doctor failed at SessionStart; plugin self-disabled.
  - Another Claude session holds the flock; plugin self-disabled.
  - current-session was cleared by a /trai:commit or /trai:discard and
    no Bash call has triggered a new SessionStart fire since.

Diagnostics:
  CLAUDE_PLUGIN_DATA: $CLAUDE_PLUGIN_DATA
  current-session:    $TRAI_CURRENT  (exists=$([[ -e "$TRAI_CURRENT" ]] && echo yes || echo no), contents="$(cat "$TRAI_CURRENT" 2>/dev/null || echo '<unreadable>')")
  XDG_STATE_HOME:     $XDG_STATE_HOME
  sessions dir:       $TRAI_SESSIONS_DIR
  session count:      $(ls -1 "$TRAI_SESSIONS_DIR" 2>/dev/null | wc -l)
  most recent:        $(ls -1t "$TRAI_SESSIONS_DIR" 2>/dev/null | head -1)

If sessions exist but current-session is empty, the pointer was cleared
mid-session. Re-running /trai:doctor or triggering a Bash call should
cause SessionStart to fire and re-populate.
EOF
  exit 0
fi

meta="$(dirname "$overlay")/meta.json"
started="unknown"; git_head=""; cwd=""
if [[ -f "$meta" ]]; then
  started="$(jq -r '.started // "unknown"' "$meta")"
  git_head="$(jq -r '.git_head // ""' "$meta")"
  cwd="$(jq -r '.cwd // ""' "$meta")"
fi

size="$(du -sh "$overlay" 2>/dev/null | awk '{print $1}' || true)"
[[ -z "$size" ]] && size="unknown"

try_bin="$(trai::try_bin 2>/dev/null || true)"
changes=0
if [[ -n "$try_bin" ]]; then
  changes="$("$try_bin" summary "$overlay" 2>/dev/null \
    | "$CLAUDE_PLUGIN_ROOT/scripts/filter-ignored.sh" \
    | grep -cE '\((added|modified|deleted)\)' || true)"
fi

cat <<EOF
trai session status
  overlay:       $overlay
  started:       $started
  cwd at start:  $cwd
  git HEAD:      ${git_head:-(not in a git repo)}
  overlay size:  $size
  changed files: $changes
  next steps:    /trai:diff | /trai:commit | /trai:discard --yes | /trai:explore
EOF
