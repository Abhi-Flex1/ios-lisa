#!/bin/bash
# Run mkiosroot-macos.sh as root with one GUI administrator prompt.
#
#   tools/mkiosroot-macos-elevated.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
# The build runs detached and logs to /tmp/mkiosroot.log so this command
# returns immediately; watch it with:
#
#   tail -f /tmp/mkiosroot.log
#
# macOS shows a password dialog ("osascript wants to make changes"). Nothing
# is flashed and no disk outside OUT.img is modified.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 4 ]] || { sed -n '2,4p' "$0"; exit 2; }
script=$PWD/tools/mkiosroot-macos.sh
# macOS TCC: a root process started by osascript cannot read ~/Desktop.
# Stage the script outside the protected folders.
stage=$(mktemp -d /tmp/mkiosroot-stage.XXXXXX)
cp "$script" "$stage/build.sh"
script=$stage/build.sh
log=/tmp/mkiosroot.$$.log
: >"$log"

# Quote every argument for the shell that osascript runs as root.
args=$(printf ' %q' "$@")
osascript -e "do shell script \"cd /tmp && '$script'$args >>'$log' 2>&1 </dev/null &\" with administrator privileges"
echo "started; log: $log"
echo "  tail -f $log"
