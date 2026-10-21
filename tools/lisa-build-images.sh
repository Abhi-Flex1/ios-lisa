#!/bin/bash
# Build every lisa test image from a CI kernel, reproducibly.
#
#   tools/lisa-build-images.sh [KERNEL]
#
# KERNEL defaults to the newest xnu/out-*/kernel.development.sweet.  Output:
#
#   shim/out/shim-boot-diag.img          v4 shim only (red diagnostic screen)
#   shim/out/shim-boot-xnu-md0.img       XNU + mockfs init, cpus=1
#   shim/out/shim-boot-xnu-md0-c4.img    XNU + mockfs init, cpus=4
#   shim/out/shim-boot-xnu-md0-c8.img    XNU + mockfs init, cpus=8
#   shim/out/shim-boot-xnu-md0-noufs.img cpus=1, ADT without /sweet-ufs
#
# Nothing here touches the phone.  The mockfs init needs no storage, so
# userdata is untouched by every image above.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

KERNEL=${1:-${KERNEL:-}}
if [ -z "$KERNEL" ]; then
	KERNEL=$(ls -t xnu/out-*/kernel.development.sweet 2>/dev/null | head -1 || true)
fi
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || {
	echo "error: no kernel; pass one or run xnu.yml and unpack xnu-kernel" >&2
	exit 1
}
case $KERNEL in /*) ;; *) KERNEL=$root/$KERNEL ;; esac

DTB=${DTB:-$root/dtb/lisa/dtb}
[ -f "$DTB" ] || { echo "error: $DTB missing (tools/lisa-device-dump.sh)" >&2; exit 1; }

# Cross toolchain: a GNU one if present, else Apple clang + host LLVM binutils.
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	:
else
	LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
	[ -x "$LLVM_BIN/llvm-objcopy" ] || LLVM_BIN=$(dirname "$(command -v llvm-objcopy)")
	[ -x "$LLVM_BIN/llvm-objcopy" ] || {
		echo "error: need aarch64-linux-gnu-gcc or LLVM (brew install llvm lld)" >&2
		exit 1
	}
	CLANG=$LLVM_BIN/clang
	[ -x "$CLANG" ] || CLANG=$(command -v clang)
	export PATH="$LLVM_BIN:/opt/homebrew/opt/lld/bin:$PATH"
	export CC="$CLANG --target=aarch64-none-elf"
	export LD="$CLANG --target=aarch64-none-elf -fuse-ld=lld"
	export OBJCOPY=$LLVM_BIN/llvm-objcopy READELF=$LLVM_BIN/llvm-readelf NM=$LLVM_BIN/llvm-nm
fi

# First-boot safety: sweet's touch driver uses SE7 I2C at 0xa84000 and
# TLMM/NORTH at 0x03900000; lisa's touch is SE13 SPI at 0xa94000 and TLMM is
# 0x0f000000.  sweet_keys_init()/sweet_touch_init() hang off
# sweet_ufs_init(), so they only run for rd=ufsroot0; the sweet USB probe
# runs from unix_startup on every boot and reads 0x88e2000, which is lisa's
# EUD window.  The PM6150 battery path is sweet-specific too.  Keep those off
# until the matching lisa driver exists.  sweetcntp=0 skips the CNTP_CTL_EL0
# write that lisa's secure monitor traps (see NOTES.md).
SAFE_ARGS="sweettouch=0 sweetkeys=0 sweetusb=0 sweetbattery=0 sweetcntp=0"

# Extra kernel boot args for one-off experiments, e.g.
#   EXTRA_ARGS="startup_debug=1 -show_pointers" tools/lisa-build-images.sh
EXTRA_ARGS=${EXTRA_ARGS:-}

# The test init: tools/sweet-init.S wrapped as a static Mach-O by mkinit.py.
RAMDISK=${RAMDISK:-/tmp/sweet-init}
if [ ! -f "$RAMDISK" ]; then
	echo "building $RAMDISK"
	clang --target=arm64-apple-ios16.0 -c tools/sweet-init.S -o /tmp/sweet-init.o
	python3 tools/mkinit.py /tmp/sweet-init.o "$RAMDISK"
fi

build_shim() { # build_shim [payload-abs] ; leaves shim/out/shim-boot.img
	BOARD=lisa DTB="$DTB" bash shim/build.sh "${1:-}"
}

echo "kernel: $KERNEL"
python3 tools/mkadt.py shim/out/lisa-hi.adt --board lisa --highmem

build_shim
cp shim/out/shim-boot.img shim/out/shim-boot-diag.img

for n in 1 4 8; do
	pay=$root/shim/out/payload-md0-c$n.bin
	python3 tools/mkpayload.py "$KERNEL" shim/out/lisa-hi.adt "$pay" \
		--ramdisk "$RAMDISK" \
		--cmdline "debug=0xc serial=3 cpus=$n keepsyms=1 -enable_kprintf_spam -noprogress rd=md0 $SAFE_ARGS $EXTRA_ARGS"
	build_shim "$pay"
	if [ "$n" = 1 ]; then
		cp shim/out/shim-boot.img shim/out/shim-boot-xnu-md0.img
	else
		cp shim/out/shim-boot.img shim/out/shim-boot-xnu-md0-c$n.img
	fi
done

# No-UFS variant: the md0 root does not use the storage driver, so this
# isolates a possible UFS probe fault from the platform bring-up.
python3 - "$root" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1] + '/tools')
import adt
root, _ = adt.parse(open(sys.argv[1] + '/shim/out/lisa-hi.adt', 'rb').read())
root.children = [c for c in root.children if c.name != 'sweet-ufs']
open(sys.argv[1] + '/shim/out/lisa-hi-noufs.adt', 'wb').write(adt.serialize(root))
EOF
pay=$root/shim/out/payload-md0-noufs.bin
python3 tools/mkpayload.py "$KERNEL" shim/out/lisa-hi-noufs.adt "$pay" \
	--ramdisk "$RAMDISK" \
	--cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0 $SAFE_ARGS $EXTRA_ARGS"
build_shim "$pay"
cp shim/out/shim-boot.img shim/out/shim-boot-xnu-md0-noufs.img

# Real iOS root on the userdata GPT partition (destructive to flash, but
# this only builds the image).  No --ramdisk: the root comes from UFS, not
# mockfs.  cmdline from docs/root-build.md; SAFE_ARGS keeps the sweet
# touch/keys/USB/battery drivers out and skips the trapped CNTP write.
pay=$root/shim/out/payload-root.bin
python3 tools/mkpayload.py "$KERNEL" shim/out/lisa-hi.adt "$pay" \
	--cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1 ignition_level=1 launchd_unsecure_cache=1 wdt=-1 $SAFE_ARGS $EXTRA_ARGS"
build_shim "$pay"
cp shim/out/shim-boot.img shim/out/shim-boot-xnu-root.img

python3 - "$root" <<'EOF'
import glob, struct, sys
root = sys.argv[1]
for f in sorted(glob.glob(root + '/shim/out/shim-boot*.img')):
	b = open(f, 'rb').read()
	ver, = struct.unpack_from('<I', b, 40)
	ks, rs = struct.unpack_from('<2I', b, 8)
	sig, = struct.unpack_from('<I', b, 1580)
	note = ''
	if ks > 0xd0000:
		img = b[4096:4096 + ks]
		note = ' payload=' + ('ok' if img[0xd0000:0xd0008] == b'SWEETXNU' else 'MISSING')
	print(f'{f.rsplit("/", 1)[-1]:34s} v{ver} kernel={ks:9d} ramdisk={rs:4d} sig={sig}{note}')
EOF

echo
echo "next (phone connected, no flash):"
echo "  fastboot boot shim/out/shim-boot-xnu-md0.img   # cpus=1, sweetcntp=0"
echo "  # diag first only when rechecking the shim:"
echo "  # fastboot boot shim/out/shim-boot-diag.img"
