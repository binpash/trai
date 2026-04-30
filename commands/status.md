---
description: Show the current trai sandbox session status (overlay path, size, changed-file count).
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-status.sh)
---

Run the status script, which reports the current session's overlay path, disk size, and number of files changed so far. If no session is active, it will say so.

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-status.sh
