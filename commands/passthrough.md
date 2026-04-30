---
description: Run the next Bash command outside the try sandbox (one-shot bypass).
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-passthrough.sh)
argument-hint: "(no arguments)"
---

Set a one-shot bypass token. The NEXT Bash command Claude runs in this session will NOT be wrapped in `try` — its effects will land on the real filesystem. The token is consumed after one use.

Use this sparingly: for commands you deliberately want to apply without review.

!${CLAUDE_PLUGIN_ROOT}/scripts/cmd-passthrough.sh
