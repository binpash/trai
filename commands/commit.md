---
description: Apply the current trai sandbox overlay to the real filesystem. DESTRUCTIVE.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-commit.sh)
---

Apply every change in the current overlay to the real filesystem, then end the session. This is destructive: file writes overwrite, deletions delete, with no second prompt after you invoke this command.

**Run `/trai:diff` first** to review what will be applied.

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-commit.sh
