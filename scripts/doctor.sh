#!/usr/bin/env bash
# scripts/doctor.sh — preflight check for trai.
# Usage:
#   scripts/doctor.sh            # verbose, exits nonzero on any failure
#   scripts/doctor.sh --quiet    # silent, exit code only
# Checks host compatibility: OS, kernel, userns, try binary, jq, flock, FS type, disk.

set -euo pipefail

. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

FAILS=0
WARNS=0

note()   { if [[ $QUIET -eq 0 ]]; then printf '  %s\n' "$*"; fi; }
ok()     { if [[ $QUIET -eq 0 ]]; then printf '  \033[32mok\033[0m   %s\n' "$*"; fi; }
warn()   { WARNS=$((WARNS+1)); if [[ $QUIET -eq 0 ]]; then printf '  \033[33mwarn\033[0m %s\n' "$*"; fi; }
fail()   { FAILS=$((FAILS+1)); if [[ $QUIET -eq 0 ]]; then printf '  \033[31mfail\033[0m %s\n' "$*"; fi; }

[[ $QUIET -eq 0 ]] && echo "trai doctor:"

# 1. OS
if [[ "$(uname -s)" != "Linux" ]]; then
  fail "OS is $(uname -s); trai is Linux-only. See docs/limitations.md."
  exit 2
fi
ok "OS is Linux"

# 2. Kernel version
kver="$(uname -r)"
kmaj="${kver%%.*}"; rest="${kver#*.}"; kmin="${rest%%.*}"
if (( kmaj > 5 || (kmaj == 5 && kmin >= 11) )); then
  ok "kernel $kver >= 5.11"
else
  fail "kernel $kver < 5.11; overlayfs in unprivileged userns requires >= 5.11. Upgrade kernel."
fi

# 3. Unprivileged user namespaces
if unshare --user --map-root-user true 2>/dev/null; then
  ok "unshare --user --map-root-user works"
else
  fail "unshare --user failed. Try: sudo sysctl kernel.unprivileged_userns_clone=1"
fi

# 4. sysctl kernel.unprivileged_userns_clone (Debian/Ubuntu variant; absent on Fedora/Arch)
if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
  val="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
  if [[ "$val" == "1" ]]; then
    ok "unprivileged_userns_clone=1"
  else
    fail "unprivileged_userns_clone=$val. Run: sudo sysctl kernel.unprivileged_userns_clone=1"
  fi
else
  ok "unprivileged_userns_clone sysctl not present (Fedora/Arch default-on)"
fi

# 5. try binary available
if try_bin="$(trai::try_bin)"; then
  ok "try found at $try_bin"
  # try -v prints to stderr
  tryver="$("$try_bin" -v 2>&1 | awk '{print $NF}')"
  if [[ -n "$tryver" ]]; then
    ok "try version $tryver"
  else
    note "try version could not be parsed; continuing"
  fi
else
  fail "try not found. Install from https://github.com/binpash/try or run: git submodule update --init vendor/try"
fi

# 6. jq
if trai::have jq; then
  ok "jq installed"
else
  fail "jq missing. Install: sudo apt install jq  OR  sudo dnf install jq  OR  pacman -S jq"
fi

# 7. flock
if trai::have flock; then
  ok "flock installed"
else
  fail "flock missing. Install util-linux."
fi

# 8. unshare
if trai::have unshare; then
  ok "unshare installed"
else
  fail "unshare missing. Install util-linux."
fi

# 9. Homedir filesystem type (warn — `try` may still work if critical dirs are local)
home_fstype="$(stat -f -c %T "$HOME" 2>/dev/null || echo unknown)"
case "$home_fstype" in
  nfs|nfs4|cifs|smb2|smb3)
    warn "\$HOME is on $home_fstype; overlayfs may refuse to stack. If session-start fails, move work to a local dir."
    ;;
  *)
    ok "\$HOME fstype: $home_fstype"
    ;;
esac

# 9b. /home and /tmp (the directories `try` typically overlays)
tmp_fstype="$(stat -f -c %T /tmp 2>/dev/null || echo unknown)"
case "$tmp_fstype" in
  nfs|nfs4|cifs|smb2|smb3)
    fail "/tmp is on $tmp_fstype; try overlays /tmp and cannot stack remote filesystems."
    ;;
  *)
    ok "/tmp fstype: $tmp_fstype"
    ;;
esac

# 10. State dir free space (>= 1 GiB)
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
mkdir -p "$state_root"
free_kb="$(df -Pk "$state_root" | awk 'NR==2 {print $4}')"
if [[ -n "$free_kb" && "$free_kb" -ge 1048576 ]]; then
  ok "state dir $state_root has $((free_kb/1024)) MiB free"
else
  fail "state dir $state_root has only $((free_kb/1024)) MiB free; need >= 1 GiB"
fi

# Summary
if [[ $QUIET -eq 0 ]]; then
  echo
  if [[ $FAILS -eq 0 ]]; then
    echo "All checks passed."
  else
    echo "$FAILS check(s) failed. See messages above."
  fi
fi

exit "$FAILS"
