#!/usr/bin/env bash
# scripts/common.sh — shared helpers for trai hooks and commands.
# Source with: . "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}/scripts/common.sh"

set -euo pipefail

# --- env resolution -----------------------------------------------------------

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${CLAUDE_PLUGIN_DATA:=${XDG_DATA_HOME:-$HOME/.local/share}/trai}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

TRAI_STATE_ROOT="$XDG_STATE_HOME/trai"
TRAI_SESSIONS_DIR="$TRAI_STATE_ROOT/sessions"
TRAI_LOCK="$TRAI_STATE_ROOT/lock"
# Runtime state (session pointer, one-shot bypass token) lives in XDG_STATE_HOME,
# NOT CLAUDE_PLUGIN_DATA. Observed failure: CLAUDE_PLUGIN_DATA lands on NFS when
# $HOME is NFS (writes silently fail), and/or its value has been seen to differ
# between hook-context and slash-command-context invocations, causing the
# session pointer to be written in one place and read from another. The plugin
# then silently loses state mid-session. XDG_STATE_HOME is set by the user
# before launching claude and is stable across every script invocation.
TRAI_CURRENT="$TRAI_STATE_ROOT/current-session"
TRAI_BYPASS="$TRAI_STATE_ROOT/bypass-next"
TRAI_DEFAULTS="$CLAUDE_PLUGIN_ROOT/config/defaults.json"
TRAI_USER_CONFIG="$CLAUDE_PLUGIN_DATA/config.json"

export CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA XDG_STATE_HOME
export TRAI_STATE_ROOT TRAI_SESSIONS_DIR TRAI_LOCK
export TRAI_CURRENT TRAI_BYPASS TRAI_DEFAULTS TRAI_USER_CONFIG

# --- small utilities ----------------------------------------------------------

trai::log() {
  # stderr only; hooks must keep stdout pure JSON
  printf '[trai] %s\n' "$*" >&2
}

trai::die() {
  trai::log "fatal: $*"
  exit 1
}

trai::have() { command -v "$1" >/dev/null 2>&1; }

# Path to the `try` binary. Prefers system PATH; falls back to vendored submodule.
trai::try_bin() {
  if trai::have try; then
    command -v try
  elif [[ -x "$CLAUDE_PLUGIN_ROOT/vendor/try/try" ]]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT/vendor/try/try"
  else
    return 1
  fi
}

# Emit a PreToolUse hook response that leaves the tool input unchanged.
# $1 (optional): additionalContext string.
trai::hook_passthrough() {
  local ctx="${1:-}"
  if [[ -n "$ctx" ]]; then
    jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
  else
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse"}}'
  fi
}

# Emit a PreToolUse hook response that rewrites the Bash command.
# $1: new command string.
# $2 (optional): additionalContext string.
trai::hook_rewrite() {
  local new_cmd="$1" ctx="${2:-}"
  if [[ -n "$ctx" ]]; then
    jq -n --arg cmd "$new_cmd" --arg ctx "$ctx" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $cmd}, additionalContext: $ctx}}'
  else
    jq -n --arg cmd "$new_cmd" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $cmd}}}'
  fi
}

# Read the current session's overlay dir. Prints path or empty.
trai::current_overlay() {
  [[ -f "$TRAI_CURRENT" ]] || return 0
  cat "$TRAI_CURRENT"
}

# Create a fresh session dir and record it as the current session.
# Prints the session dir path.
trai::new_session() {
  local sid ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  sid="${ts}-$$"
  local dir="$TRAI_SESSIONS_DIR/$sid"
  mkdir -p "$dir/overlay"
  mkdir -p "$(dirname "$TRAI_CURRENT")"
  printf '%s' "$dir/overlay" > "$TRAI_CURRENT"
  printf '%s\n' "$dir/overlay"
}

# Clear the current session pointer. Does not delete overlay files.
trai::clear_session() {
  : > "$TRAI_CURRENT"
}

# Merge default + user config (user overrides take precedence).
# Prints merged JSON.
trai::config() {
  if [[ -f "$TRAI_USER_CONFIG" ]]; then
    jq -s '.[0] * .[1]' "$TRAI_DEFAULTS" "$TRAI_USER_CONFIG"
  else
    cat "$TRAI_DEFAULTS"
  fi
}

# Return 0 if a bypass token is set (one-shot via /trai:passthrough).
# Consumes (deletes) the token on first check.
trai::consume_bypass() {
  local tok="$TRAI_BYPASS"
  if [[ -f "$tok" ]]; then
    rm -f "$tok"
    return 0
  fi
  return 1
}
