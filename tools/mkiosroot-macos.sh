#!/bin/bash
# Build the iOS root HFS+ image on macOS (native APFS, no Linux host).
#
#   sudo tools/mkiosroot-macos.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]
#
# This is the same recipe as mkiosroot.sh (see its header for why each step is
# there), implemented with the tools macOS already has:
#
#   - DMGs are mounted with hdiutil (native APFS, LZBITMAP decompressed on
#     read) instead of apfs-fuse.
#   - the image is created as a raw file, formatted with newfs_hfs
#     (case-sensitive, journaled) and mounted with `mount -t hfs`; ownership
#     is enabled, so root can preserve uid/gid.
#   - pax -rw -pe copies the trees (preserves owners, modes, symlinks and
#     hard links; openrsync on current macOS cannot hard-link).
#
# Must run as root: use tools/mkiosroot-macos-elevated.sh, which prompts for
# the administrator password in a GUI dialog.
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,4p' "$0"; exit 2; }
[[ $(id -u) == 0 ]] || { echo "error: run as root (mkiosroot-macos-elevated.sh)" >&2; exit 1; }

os=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
sysos=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
appos=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
out=$4
size=${5:-16G}
[[ -f $os && -f $sysos && -f $appos ]] || { echo "error: missing DMG" >&2; exit 1; }
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
out=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
dev=
rootmnt=$work/root
attach_apfs() { # prints "<mountpoint> <dev-entry>"
	python3 - "$1" <<'PY'
import plistlib, subprocess, sys, os
img = sys.argv[1]
def run(args):
    p = subprocess.run(args, capture_output=True)
    return p.returncode, p.stdout
rc, out = run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-plist', img])
if rc != 0:
    rc, out = run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                   '-imagekey', 'diskimage-class=CRawDiskImage', '-plist', img])
if rc != 0:
    sys.exit('hdiutil attach failed for %s' % img)
d = plistlib.loads(out)
best = None
for e in d.get('system-entities', []):
    mp = e.get('mount-point')
    if not mp:
        continue
    # Prefer the volume literally named "root"; else any volume that looks
    # like a system root (the 3 DMGs each carry one).
    rank = 0 if e.get('volume-name') == 'root' else 1 if os.path.isdir(mp + '/System/Library') else 2
    if best is None or rank < best[0]:
        best = (rank, mp, e.get('dev-entry'))
if best is None:
    sys.exit('no mounted volume in %s' % img)
print(best[1]); print(best[2] or '')
PY
}

cleanup() {
	if mount | grep -q " on $rootmnt "; then umount "$rootmnt" 2>/dev/null || true; fi
	if [[ -n $dev ]]; then hdiutil detach "$dev" >/dev/null 2>&1 || true; fi
	rmdir "$rootmnt" 2>/dev/null || true
	rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

# 1. raw image + case-sensitive journaled HFS+
echo "== creating $out ($size)"
truncate -s "$size" "$out"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$out" | awk 'NR==1{print $1}')
[[ -n $dev ]] || { echo "error: could not attach $out" >&2; exit 1; }
rdev=/dev/r${dev##*/}
newfs_hfs -s -J -v iOSRoot "$rdev"
mkdir -p "$rootmnt"
mount -t hfs "$dev" "$rootmnt"

copy() { # dmg dest-relative
	echo "== copying $1 -> /${2:-}"
	local mp d
	{ read -r mp; read -r d; } < <(attach_apfs "$1")
	[[ -d $mp ]] || { echo "error: no mount for $1" >&2; exit 1; }
	mkdir -p "$rootmnt/${2:-}"
	(cd "$mp" && pax -rw -pe . "$rootmnt/${2:-}")
	hdiutil detach "$d" >/dev/null
}

copy "$os" ""
copy "$sysos" private/preboot/Cryptexes/OS
copy "$appos" private/preboot/Cryptexes/App

# 2. shared cache where dyld looks at ignition_level=1 (hard links, no space)
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$rootmnt/System/Library/Caches/com.apple.dyld"
for f in "$rootmnt/$dsc"/*; do
	[[ -e $f ]] && ln "$f" "$rootmnt/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# 3. everything else in the cryptexes that the OS root lacks
for c in OS App; do
	(cd "$rootmnt/private/preboot/Cryptexes/$c" &&
		find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $rootmnt/$f && ! -L $rootmnt/$f ]]; then
			mkdir -p "$rootmnt/$(dirname "$f")"
			src=$rootmnt/private/preboot/Cryptexes/$c/$f
			if [[ -L $src ]]; then cp -P "$src" "$rootmnt/$f"; else ln "$src" "$rootmnt/$f"; fi
		fi
	done
done

# 4. logd stores (owner _logd 272, mode, .migrated) or logd panics on migrate
db=$rootmnt/private/var/db
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# 5. system keybag for the built-in AppleKeyStore (no passcode)
install -d -m 0700 -o 0 -g 0 "$rootmnt/private/var/keybags"
kb=$work/systembag.kb
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' >"$kb"
install -m 0600 -o 0 -g 0 "$kb" "$rootmnt/private/var/keybags/systembag.kb"

df -h "$rootmnt" | tail -1
umount "$rootmnt"
fsck_hfs -f -n "$rdev" || true
hdiutil detach "$dev" >/dev/null
dev=
echo "== done: $out"
ls -lh "$out"
