#!/usr/bin/env bash
# scripts/filter-ignored.sh — drop state-file noise from `try summary` output.
# Usage: try summary <overlay> | scripts/filter-ignored.sh

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

# Build a pipe-separated regex from the ignore list.
# Patterns are prefix matches on absolute paths; $HOME and $XDG_STATE_HOME are expanded.
build_regex() {
  local pats
  pats="$(trai::config | jq -r '.ignore[]')"
  local regex=""
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    # Expand $HOME, $XDG_STATE_HOME
    pat="${pat//\$HOME/$HOME}"
    pat="${pat//\$XDG_STATE_HOME/${XDG_STATE_HOME:-$HOME/.local/state}}"
    # Escape regex special chars, then allow the path to be a prefix
    esc="$(printf '%s' "$pat" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')"
    if [[ -z "$regex" ]]; then
      regex="$esc"
    else
      regex="$regex|$esc"
    fi
  done <<< "$pats"
  printf '%s' "$regex"
}

regex="$(build_regex)"

if [[ -z "$regex" ]]; then
  # no patterns — pass through
  cat
  exit 0
fi

# `try summary` output is roughly "STATUS PATH" lines; filter any line whose PATH starts with an ignored prefix.
# Use grep -vE so ignored paths disappear.
grep -vE "(^|[[:space:]])($regex)" || true
