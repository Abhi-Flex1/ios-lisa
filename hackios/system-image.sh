#!/bin/bash
# Build the iOS 16.5 system image that the kernel needs as its root: the
# upstream userland repo, then Apple's IPSW, then root.apfs + system.apfs.
#
# usage: hackios/system-image.sh [WORK]        (default: ~/Desktop/ios-lisa-work/hackios)
#
# Why the WORK tree and not this repo: HackiOS is two repositories checked out
# into one directory (kernel + userland, see common/setup.sh upstream), and the
# userland scripts reach into the kernel tree (xnu-deps/, tools/apfs/).  This
# repository only carries our lisa patches and images, so the tree lives
# outside it and is rebuilt from the pinned SHAs in hackios/pins.env.
#
# What it needs and costs:
#   python3, git, curl, gcc (Xcode CLT), 7z (7-Zip 23+: `brew install sevenzip`,
#   whose binary is 7zz -- fetch.sh wants the name 7z, so a symlink is made)
#   ~8 GB free while fetching (5.3 GB after), ~2.5 GB for system.apfs
#   7.4 GB of download from Apple's CDN (4.7 GB root filesystem, 2.7 GB cryptex)
# No Apple file ends up in this repository.
#
# Then, with the phone in the loader (./xl enter):
#   ./xl ramdisk userland/system.apfs     # once per loader session, 2.5 GB over USB
#   XL_RAMDISK=userland/root.apfs XL_CMDLINE="-v touchscreen=0" ./xl run
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pins.env"
WORK=${1:-$HOME/Desktop/ios-lisa-work/hackios}

# macOS only.  ios165/fetch.sh and userland/build.sh are written for Linux:
#   * BSD wc pads its count ("       0") and fetch.sh tests `[ "$(… | wc -l)" = 0 ]`,
#     so a good extraction is reported as incomplete (GNU coreutils fixes it);
#   * build.sh calls `timedatectl show -p Timezone --value`, which does not
#     exist here, and the failing substitution aborts the script under `set -e`;
#   * build.sh edits var.skel with `sed -i -e` and `\t` in the pattern, which
#     BSD sed neither accepts nor understands (GNU sed: brew install gnu-sed).
# So a temporary shim directory goes in front of PATH: `sed` -> gsed, and a
# `timedatectl` that answers this Mac's zone.
SHIM=
if [ "$(uname -s)" = Darwin ]; then
	for p in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin; do
		[ -d "$p" ] && PATH="$p:$PATH"
	done
	GSED=$(command -v gsed || command -v sed)
	SHIM=$(mktemp -d "${TMPDIR:-/tmp}/ios-lisa-shim.XXXXXX")
	printf '#!/bin/sh\nexec %s "$@"\n' "$GSED" > "$SHIM/sed"
	cat > "$SHIM/timedatectl" <<'SHIMEOF'
#!/bin/sh
# what `timedatectl show -p Timezone --value` answers on Linux; build.sh
# falls back to UTC when this prints nothing.
case "$*" in
*Timezone*) z=$(readlink /etc/localtime); echo "${z##*/zoneinfo/}" ;;
*) echo UTC ;;
esac
SHIMEOF
	chmod +x "$SHIM/sed" "$SHIM/timedatectl"
	PATH="$SHIM:$PATH"
	trap '[ -n "$SHIM" ] && rm -rf "$SHIM"' EXIT
	export PATH
fi

need() { command -v "$1" >/dev/null || { echo "system-image: $1 is missing ($2)" >&2; exit 1; }; }
need git "to check out the HackiOS trees"
need python3 "ios165/fetch.sh"
need curl "to fetch iOS from Apple"
need cc "ios165/fetch.sh builds the LZBITMAP decoder"
need 7z "7-Zip 23+ reads APFS: brew install sevenzip"

# 7z must be free for the disk that the extraction needs next to the downloads.
free_gb=$(df -g "$WORK" 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$free_gb" ] && [ "$free_gb" -lt 10 ] &&
	echo "system-image: warning: $free_gb GB free in $WORK, the fetch wants about 8" >&2

if [ ! -d "$WORK" ]; then
	echo "== cloning hackios-xnu-kernel"
	mkdir -p "$(dirname "$WORK")"
	git clone "$HACKIOS_KERNEL_REPO" "$WORK"
fi
cd "$WORK"
git fetch -q origin "$HACKIOS_KERNEL_SHA:refs/remotes/origin/pinned" 2>/dev/null || true
git checkout -q "$HACKIOS_KERNEL_SHA" 2>/dev/null ||
	{ echo "system-image: $WORK is not at the pinned kernel SHA; fix or move it" >&2; exit 1; }

# The userland is a second checkout in the same directory (git dir .userland.git).
if [ -d .userland.git ]; then
	echo "== userland already checked out, updating to $HACKIOS_USERLAND_SHA"
	git --git-dir=.userland.git --work-tree=. fetch -q origin
	git --git-dir=.userland.git --work-tree=. checkout -q "$HACKIOS_USERLAND_SHA"
else
	echo "== checking out the userland at $HACKIOS_USERLAND_SHA"
	USERLAND_REF="$HACKIOS_USERLAND_SHA" ./common/setup.sh >/dev/null
fi
echo "system-image: kernel   $(git rev-parse HEAD)"
echo "system-image: userland $(git --git-dir=.userland.git rev-parse HEAD)"

# Our patches to the userland checkout (none upstream): the prebuilt-only build
# path, the one used here without theos/ld64, copies a program prebuilt/ has not
# got.  --check first so a second run is a no-op.
for p in "$HERE"/patches-userland/*.patch; do
	[ -f "$p" ] || continue
	git --git-dir=.userland.git --work-tree=. apply --check "$p" 2>/dev/null || continue
	git --git-dir=.userland.git --work-tree=. apply "$p"
	echo "system-image: applied $(basename "$p")"
done

if [ ! -f ios165/.done-cryptex-app ]; then
	echo "== fetching iOS 16.5 from Apple (7.4 GB, this takes a while)"
	./ios165/fetch.sh
fi
echo "== building root.apfs and system.apfs"
PREBUILT=1 REST=1 ./userland/build.sh
ls -l userland/root.apfs userland/system.apfs
cat <<'EOF'

Next, with the phone in the loader:
  ./xl ramdisk userland/system.apfs
  XL_RAMDISK=userland/root.apfs XL_CMDLINE="-v touchscreen=0" ./xl run
EOF
