---
description: Show the filesystem diff accumulated in the current trai sandbox overlay.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-diff.sh)
---

Print the list of files the sandboxed Bash calls in this session have added, modified, or deleted so far. Ignored noise paths (`~/.claude`, caches, histories) are filtered out.

Run this before `/trai:commit` to review what will be applied.

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-diff.sh
