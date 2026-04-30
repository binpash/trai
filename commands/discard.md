---
description: Discard the current trai sandbox overlay (requires --yes).
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-discard.sh *)
argument-hint: "--yes"
---

Remove the current session's overlay directory without committing. The user **must** pass `--yes` to confirm.

Usage: `/trai:discard --yes`

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-discard.sh $ARGUMENTS
