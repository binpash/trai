---
description: Run trai's preflight health check and print any remediation instructions.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh)
---

Run the full preflight check: OS, kernel version, unprivileged user namespaces, `try` binary, `jq`, `flock`, filesystem types, disk space.

!${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh
