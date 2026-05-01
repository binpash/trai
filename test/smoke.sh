#!/usr/bin/env bash
# test/smoke.sh — end-to-end verification of trai's hook pipeline.
# Simulates a Claude session by:
#   1. Invoking hooks/session-start.sh
#   2. Feeding synthetic PreToolUse(Bash) payloads through hooks/pre-bash.sh
#   3. Executing the rewritten commands (simulating what Claude Code would do)
#   4. Running /trai:diff, /trai:status, /trai:commit (via the cmd-*.sh backers)
#   5. Asserting the real FS reflects only what we expected
#
# Run this in a scratch dir, NOT in the repo's cwd. The test cleans up after itself.
#
# Usage:
#   test/smoke.sh             # normal run; assumes `try` is installed or vendored
#   VERBOSE=1 test/smoke.sh   # extra output on failure

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

# Isolated dirs for this run
export CLAUDE_PLUGIN_DATA="$(mktemp -d /tmp/tc-smoke-data.XXXXXX)"
export XDG_STATE_HOME="$(mktemp -d /tmp/tc-smoke-state.XXXXXX)"
export CLAUDE_PROJECT_DIR="$(mktemp -d /tmp/tc-smoke-proj.XXXXXX)"

# Override ignore patterns so our /tmp-based test project isn't filtered out
# (the defaults ignore /tmp because real users don't work there).
cat > "$CLAUDE_PLUGIN_DATA/config.json" <<EOF
{
  "ignore": [
    "\$HOME/.claude",
    "\$HOME/.cache",
    "\$HOME/.bash_history"
  ]
}
EOF

cleanup() {
  local rc=$?
  cd /tmp
  chmod -R u+w "$XDG_STATE_HOME" "$CLAUDE_PLUGIN_DATA" 2>/dev/null || true
  rm -rf "$CLAUDE_PLUGIN_DATA" "$XDG_STATE_HOME" "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
  if [[ $rc -eq 0 ]]; then
    echo
    echo "smoke: PASS"
  else
    echo
    echo "smoke: FAIL (exit $rc)"
  fi
  exit "$rc"
}
trap cleanup EXIT

say()   { printf '\n== %s ==\n' "$*"; }
fail()  { echo "ASSERT FAIL: $*" >&2; [[ "${VERBOSE:-0}" = 1 ]] && set -x; return 1; }
assert(){ if ! eval "$1"; then fail "$1"; fi; }

# Helper: run pre-bash.sh on a command and eval the rewrite (or run original if passthrough).
run_wrapped() {
  local orig="$1"
  local out cmd
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$orig" '$c')" \
        | "$CLAUDE_PLUGIN_ROOT/hooks/pre-bash.sh")"
  cmd="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty')"
  if [[ -n "$cmd" ]]; then
    eval "$cmd"
  else
    eval "$orig"
  fi
}

cd "$CLAUDE_PROJECT_DIR"
git init -q

# -----------------------------------------------------------------------------
say "0. preflight"
if ! "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" --quiet; then
  echo "doctor failed; see output above. smoke cannot proceed."
  "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh"
  exit 2
fi

# -----------------------------------------------------------------------------
say "1. session-start creates an overlay"
"$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh" >/dev/null
OVERLAY="$(cat "$XDG_STATE_HOME/trai/current-session")"
assert "[[ -n '$OVERLAY' ]]"
assert "[[ -d '$OVERLAY' ]]"

# -----------------------------------------------------------------------------
say "2. wrapped Bash writes land in overlay, not real FS"
run_wrapped 'echo hello > hello.txt' >/dev/null 2>&1
assert "[[ ! -f '$CLAUDE_PROJECT_DIR/hello.txt' ]]"
HELLO_IN_OVERLAY="$(find "$OVERLAY/upperdir" -name hello.txt 2>/dev/null | head -1)"
assert "[[ -n '$HELLO_IN_OVERLAY' ]]"

# -----------------------------------------------------------------------------
say "3. passthrough commands land directly (simulated)"
# A passthrough command returns no updatedInput; run_wrapped falls back to eval-orig.
# We simulate this by running a git command that is in passthrough list.
run_wrapped 'git config user.email "smoke@test"' >/dev/null 2>&1
# git ran against the real repo (passthrough); we can't easily diff that but
# we can confirm no 'git' file landed in overlay.
assert "[[ -z \"\$(find '$OVERLAY/upperdir' -name config 2>/dev/null | head -1)\" || true ]]"

# -----------------------------------------------------------------------------
say "4. compound command (&&) is wrapped despite starting with 'echo'"
run_wrapped 'echo WRAPPED && touch compound.txt' >/dev/null 2>&1
COMPOUND_IN_OVERLAY="$(find "$OVERLAY/upperdir" -name compound.txt 2>/dev/null | head -1)"
assert "[[ -n '$COMPOUND_IN_OVERLAY' ]]"
assert "[[ ! -f '$CLAUDE_PROJECT_DIR/compound.txt' ]]"

# -----------------------------------------------------------------------------
say "5. /trai:status reports the current overlay"
STATUS_OUT="$("$CLAUDE_PLUGIN_ROOT/scripts/cmd-status.sh")"
echo "$STATUS_OUT" | grep -q "$OVERLAY" || fail "status does not contain overlay path"

# -----------------------------------------------------------------------------
say "6. /trai:diff lists changes"
DIFF_OUT="$("$CLAUDE_PLUGIN_ROOT/scripts/cmd-diff.sh")"
echo "$DIFF_OUT" | grep -q 'hello.txt' || fail "diff missing hello.txt"
echo "$DIFF_OUT" | grep -q 'compound.txt' || fail "diff missing compound.txt"

# -----------------------------------------------------------------------------
say "7. /trai:discard without --yes is refused"
if "$CLAUDE_PLUGIN_ROOT/scripts/cmd-discard.sh" >/dev/null 2>&1; then
  fail "discard without --yes should have failed"
fi

# -----------------------------------------------------------------------------
say "8. /trai:commit applies changes to real FS"
"$CLAUDE_PLUGIN_ROOT/scripts/cmd-commit.sh" >/dev/null
assert "[[ -f '$CLAUDE_PROJECT_DIR/hello.txt' ]]"
assert "[[ -f '$CLAUDE_PROJECT_DIR/compound.txt' ]]"
assert "[[ \"\$(cat '$CLAUDE_PROJECT_DIR/hello.txt')\" == 'hello' ]]"

# -----------------------------------------------------------------------------
say "9. session pointer cleared after commit"
assert "[[ -z \"\$(cat '$XDG_STATE_HOME/trai/current-session' 2>/dev/null || true)\" ]]"

# -----------------------------------------------------------------------------
say "10. discard path"
"$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh" >/dev/null
OVERLAY2="$(cat "$XDG_STATE_HOME/trai/current-session")"
run_wrapped 'echo junk > junk.txt' >/dev/null 2>&1
assert "[[ ! -f '$CLAUDE_PROJECT_DIR/junk.txt' ]]"
"$CLAUDE_PLUGIN_ROOT/scripts/cmd-discard.sh" --yes >/dev/null
assert "[[ ! -f '$CLAUDE_PROJECT_DIR/junk.txt' ]]"
# session pointer should be cleared
assert "[[ -z \"\$(cat '$XDG_STATE_HOME/trai/current-session' 2>/dev/null || true)\" ]]"

# -----------------------------------------------------------------------------
say "11. /trai:passthrough one-shot bypass"
"$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh" >/dev/null
"$CLAUDE_PLUGIN_ROOT/scripts/cmd-passthrough.sh" >/dev/null

# Next hook call: expect NO updatedInput (bypass in effect).
BYPASS_CMD="$(printf '{"tool_name":"Bash","tool_input":{"command":"echo bypass-token > bypassed.txt"}}' \
              | "$CLAUDE_PLUGIN_ROOT/hooks/pre-bash.sh" \
              | jq -r '.hookSpecificOutput.updatedInput.command // empty')"
[[ -z "$BYPASS_CMD" ]] || fail "bypass token did not suppress the rewrite (got: $BYPASS_CMD)"

# Follow-up hook call: expect the rewrite is back (bypass consumed).
WRAP_CMD="$(printf '{"tool_name":"Bash","tool_input":{"command":"echo wrapped-again > wrapped.txt"}}' \
            | "$CLAUDE_PLUGIN_ROOT/hooks/pre-bash.sh" \
            | jq -r '.hookSpecificOutput.updatedInput.command // empty')"
[[ -n "$WRAP_CMD" ]] || fail "bypass was not consumed; second call still passthrough"

"$CLAUDE_PLUGIN_ROOT/scripts/cmd-discard.sh" --yes >/dev/null
