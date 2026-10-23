#!/bin/bash
# Clone one upstream repository at an exact commit, without its history.
#
# usage: ci-fetch.sh DEST REPO SHA [SUBMODULES=0|1]
#
# HackiOS's own scripts do the same for single commits (xnu-deps/setup.sh
# "fetch"), and xnu/apply.sh pins the XNU tag the same way; this is only for
# the two trees we build from.
set -e
DEST=$1 REPO=$2 SHA=$3 SUBS=${4:-0}
[ -n "$DEST" ] && [ -n "$REPO" ] && [ -n "$SHA" ] || {
	echo "usage: ci-fetch.sh DEST REPO SHA [SUBMODULES]" >&2; exit 2; }
rm -rf "$DEST"
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin "$REPO"
git -C "$DEST" fetch -q --depth 1 origin "$SHA"
git -C "$DEST" -c advice.detachedHead=false checkout -q FETCH_HEAD
if [ "$SUBS" = 1 ]; then
	# no --depth: submodules are pinned to commits the server may not advertise
	git -C "$DEST" submodule update -q --init --recursive
fi
echo "ci-fetch: $DEST at $SHA ($(git -C "$DEST" log -1 --format='%cs %s' | cut -c1-60))"
