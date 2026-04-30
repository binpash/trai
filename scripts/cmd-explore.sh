#!/usr/bin/env bash
# scripts/cmd-explore.sh — backs /trai:explore. Prints the command to paste.
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/common.sh"

overlay="$(trai::current_overlay)"
if [[ -z "$overlay" ]]; then
  echo "trai: no active session."
  exit 0
fi

try_bin="$(trai::try_bin 2>/dev/null || echo try)"

cat <<EOF
trai: to explore the overlay interactively, paste the following into your own terminal:

    $try_bin explore $overlay

You will get a shell inside the sandboxed view. Changes you make there will
not land on the real FS until you run /trai:commit.
EOF
