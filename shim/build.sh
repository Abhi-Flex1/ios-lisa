#!/bin/bash
# Build the shim and wrap it in a boot.img v2.
#
#   BOARD=lisa ./build.sh [payload.bin]     (default; Xiaomi 11 Lite 5G NE)
#   BOARD=sweet ./build.sh [payload.bin]    (upstream SM7150 baseline)
#
# CROSS/CC/OBJCOPY can be overridden for a local clang or a different
# toolchain; the freestanding shim needs no libc.
set -euo pipefail
cd "$(dirname "$0")"

BOARD=${BOARD:-lisa}
case "$BOARD" in
	lisa|sweet) ;;
	*) echo "error: BOARD must be lisa or sweet, got '$BOARD'" >&2; exit 1 ;;
esac
DEF=-DBOARD_$(echo "$BOARD" | tr '[:lower:]' '[:upper:]')

CROSS=${CROSS:-aarch64-linux-gnu-}
CC=${CC:-${CROSS}gcc}
OBJCOPY=${OBJCOPY:-${CROSS}objcopy}
READELF=${READELF:-${CROSS}readelf}
NM=${NM:-${CROSS}nm}

if [ "$BOARD" = lisa ]; then
	DTB=${DTB:-../board/lisa/lisa.dtb}
	if [ "$DTB" = ../board/lisa/lisa.dtb ]; then
		echo "warning: using the bundled lisa DTB; run tools/lisa-device-dump.sh and" >&2
		echo "         compare it with the phone's own dtb/lisa/dtb before booting" >&2
	fi
else
	DTB=${DTB:-../dtb/boot_unpacked/dtb}
fi
[ -f "$DTB" ] || { echo "error: stock DTB $DTB missing (see docs/lisa-hardware.md)" >&2; exit 1; }

CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra $DEF"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
end=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
size=$((0x$end))
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
MKBOOTIMG=$(command -v mkbootimg || true)
if [ -n "$MKBOOTIMG" ]; then
	$MKBOOTIMG --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
else
	python3 ../tools/mkbootimg.py --header_version 2 --kernel out/Image \
		--ramdisk out/ramdisk.bin --dtb "$DTB" --base 0 \
		--kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
fi
# Host render of the console layout.
gcc -O1 -Wall -DBOARD_$(echo "$BOARD" | tr '[:lower:]' '[:upper:]') -o out/host_test console.c host_test.c && ./out/host_test
echo "board: $BOARD  dtb: $DTB"
ls -l out/Image out/shim-boot.img
