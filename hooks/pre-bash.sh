#!/usr/bin/env bash
# hooks/pre-bash.sh — PreToolUse(Bash) hook.
# Reads Claude's JSON on stdin, decides whether to wrap the command in `try`,
# and emits a hookSpecificOutput with updatedInput on stdout.

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

# Read the full hook payload
payload="$(cat)"

# Extract the command. If jq fails or command is missing, pass through silently.
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
if [[ -z "$cmd" ]]; then
  trai::hook_passthrough
  exit 0
fi

# Strip a leading ! that Claude Code slash-command bodies emit (the `!cmd`
# convention means "run this shell command"). Without stripping it the
# plugin-root self-exemption below misses `!/path/to/plugin/script` and the
# command gets sandboxed, where `!path` is an invalid shell token.
cmd="${cmd#!}"

# Never sandbox the plugin's own scripts. /trai:* slash commands expand to
# Bash(${CLAUDE_PLUGIN_ROOT}/scripts/...). Those need to (a) read/write plugin
# state files on the REAL filesystem (bypass tokens, session pointer) and
# (b) introspect the real host, not the overlay. A glob on the plugin root
# (stripped of trailing /) matches both /root/... and /root//... forms.
root="${CLAUDE_PLUGIN_ROOT%/}"
case "$cmd" in
  "$root"/*)
    trai::hook_passthrough "trai: plugin-internal script; not sandboxed."
    exit 0
    ;;
esac

# Plugin inactive for this session? (doctor failed, or no current-session)
overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  trai::hook_passthrough
  exit 0
fi

# One-shot bypass via /trai:passthrough
if trai::consume_bypass; then
  trai::hook_passthrough "trai: one-shot passthrough honored."
  exit 0
fi

# Configured passthrough patterns
if "$CLAUDE_PLUGIN_ROOT/scripts/is-passthrough.sh" "$cmd"; then
  if [[ "$(trai::config | jq -r '.warnOnPassthrough // false')" == "true" ]]; then
    trai::hook_passthrough "trai: command matched passthrough list; not sandboxed."
  else
    trai::hook_passthrough
  fi
  exit 0
fi

# Ensure the overlay dir still exists (user may have /trai:discarded mid-session)
if [[ ! -d "$overlay" ]]; then
  mkdir -p "$overlay"
fi

# Upstream `try` requires temproot/ to be empty-of-non-directories before it will
# accept a sandbox (validity check in try's sandbox_valid_or_empty). try's own
# chroot setup creates symlinks under temproot/ (e.g. temproot/bin -> usr/bin
# for mountpoints that are symlinks on the host) and its cleanup isn't always
# reliable — leftovers cause the next invocation to fail with
#   "sandbox 'X' is invalid"  or
#   "ln: failed to create symbolic link 'temproot//bin/bin': Permission denied".
# User data lives in upperdir/, never in temproot/, so it's safe to purge.
if [[ -d "$overlay/temproot" ]]; then
  find "$overlay/temproot" -mindepth 1 -delete 2>/dev/null || true
fi

# Locate `try`
if ! try_bin="$(trai::try_bin)"; then
  trai::hook_passthrough "trai: try binary not found; command not sandboxed."
  exit 0
fi

# Build the wrapped command. try's internals (`echo "$@"` into a sourced script)
# collapse multi-arg invocations with spaces, which mangles `bash -c '...'`.
# The workaround is to pass the whole command as a SINGLE argument; try writes
# it verbatim to script_to_execute.sh and sources it as shell code, preserving
# all pipes, redirects, &&, ||, and quoting.
# -D implies -n (no commit prompt) so we do not pass -n separately.
esc_cmd="${cmd//\'/\'\\\'\'}"     # escape embedded single quotes
wrapped="$(printf "%q -D '%s' '%s'" "$try_bin" "$overlay" "$esc_cmd")"

trai::hook_rewrite "$wrapped" "trai: sandboxed into $overlay"
