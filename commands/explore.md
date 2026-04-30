---
description: Print the shell command to launch an interactive `try explore` shell inside the current overlay.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-explore.sh)
---

Print the exact `try explore <overlay>` command for the user to paste into their own terminal. Claude's TUI cannot host an interactive shell for the overlay, so we surface the command instead.

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-explore.sh
