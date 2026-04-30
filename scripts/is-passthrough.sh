#!/usr/bin/env bash
# scripts/is-passthrough.sh — decide whether a Bash command should bypass the `try` wrapper.
# Usage: scripts/is-passthrough.sh "<command string>"
# Exit 0 => passthrough (do not wrap); exit 1 => wrap under try.

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

cmd="${1:-}"
[[ -z "$cmd" ]] && exit 1

# Refuse to passthrough compound commands. If the command contains any shell
# metacharacters that indicate multiple statements / pipes / redirects / substitutions,
# we route it through `try` even if it looks like it starts with a passthrough name.
# This prevents e.g. `git log | tee /root/.bashrc` from being passthrough-ed because
# it starts with `git`.
case "$cmd" in
  *'&&'*|*'||'*|*'|'*|*';'*|*'>'*|*'<'*|*'$('*|*'`'*|*'&'*)
    exit 1
    ;;
esac

# Normalize: strip leading whitespace, unwrap common process wrappers so e.g.
# `timeout 10 git status` is still recognized as a git call.
trim="${cmd#"${cmd%%[![:space:]]*}"}"
for wrapper_prefix in 'timeout ' 'time ' 'nice ' 'nohup ' 'stdbuf ' 'xargs '; do
  if [[ "$trim" == "$wrapper_prefix"* ]]; then
    rest="${trim#$wrapper_prefix}"
    # strip the wrapper's own flags
    while [[ "$rest" == -* ]]; do rest="${rest#* }"; done
    # timeout/stdbuf require one positional arg (duration / io-spec) before the real command
    case "$wrapper_prefix" in
      'timeout '|'stdbuf ') rest="${rest#* }" ;;
    esac
    trim="$rest"
  fi
done

# Read passthrough patterns; match command prefix against each.
# Pattern "git" matches exactly "git"; "git *" matches "git <anything>".
mapfile -t patterns < <(trai::config | jq -r '.passthrough[]')

for pat in "${patterns[@]}"; do
  case "$pat" in
    *' *')
      prefix="${pat% \*}"
      # shellcheck disable=SC2053
      [[ "$trim" == $prefix' '* ]] && exit 0
      ;;
    *)
      [[ "$trim" == "$pat" ]] && exit 0
      ;;
  esac
done

exit 1
