#!/bin/bash
# Read-only inventory of a Xiaomi 11 Lite 5G NE (lisa) for the ios-lisa port.
#
# Works on booted Android with root (adb root / su) or in OrangeFox/TWRP with
# adb. Nothing is written to the phone. Backups land in backup/ (gitignored),
# because persist/modemst/fsg contain the IMEI and factory calibration.
#
#   tools/lisa-device-dump.sh            # detect mode, dump what is possible
#   tools/lisa-device-dump.sh --boot     # only pull boot/dtbo/vbmeta
#
# Every destructive step (flashing, erasing userdata) is deliberately absent.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p backup dbg/dt

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

have adb || { echo "adb not found" >&2; exit 1; }
adb start-server >/dev/null 2>&1 || true

state=$(adb get-state 2>/dev/null || true)
if [ "$state" != device ]; then
	echo "No adb device. Connect the phone (booted Android with USB debugging, or"
	echo "a recovery with adb), then rerun. In fastboot, use 'fastboot devices'"
	echo "and 'fastboot getvar all' manually for the bootloader inventory."
	exit 1
fi

say "identity"
adb shell getprop ro.product.device
adb shell getprop ro.boot.hardware.sku
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell getprop ro.boot.hwversion
adb shell getprop ro.boot.hwc
adb shell getprop ro.boot.verifiedbootstate

say "memory"
adb shell cat /proc/meminfo | head -3
echo "--- /proc/iomem System RAM (this is the authoritative RAM map) ---"
adb shell cat /proc/iomem 2>/dev/null | grep -i "system ram" || \
	echo "(needs root: run 'adb root' or use a recovery)"

say "kernel / cmdline"
adb shell cat /proc/cmdline || true

say "partitions"
adb shell 'ls -l /dev/block/by-name 2>/dev/null' || true

ROOT=""
if adb shell 'id' 2>/dev/null | grep -q 'uid=0'; then
	ROOT=1
elif adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
	ROOT="su"
fi

if [ -n "$ROOT" ]; then
	say "backing up boot / dtbo / vbmeta (read-only)"
	for part in boot dtbo vbmeta; do
		adb shell "$ROOT -c 'dd if=/dev/block/by-name/$part of=/sdcard/$part.img bs=4M'" 2>/dev/null || \
			adb shell "dd if=/dev/block/by-name/$part of=/sdcard/$part.img bs=4M" || true
		adb pull "/sdcard/$part.img" "backup/$part.img" 2>/dev/null || true
		adb shell rm -f "/sdcard/$part.img" || true
	done
	say "dumping the live device tree"
	adb shell "$ROOT -c 'cat /sys/firmware/fdt'" > dbg/fdt.dtb 2>/dev/null || true
	if [ -s dbg/fdt.dtb ]; then
		echo "saved dbg/fdt.dtb ($(wc -c < dbg/fdt.dtb) bytes)"
	fi
else
	echo
	echo "Not root: skipping partition and FDT dumps. Use OrangeFox (temporary"
	echo "'fastboot boot recovery.img') and rerun, or pull them manually."
fi

if [ -f backup/boot.img ]; then
	say "unpacking boot.img -> dtb/lisa"
	python3 tools/unpack_bootv2.py backup/boot.img dtb/lisa || true
	if [ -f dtb/lisa/dtb ]; then
		echo "phone DTB: dtb/lisa/dtb"
		if cmp -s dtb/lisa/dtb board/lisa/lisa.dtb; then
			echo "matches board/lisa/lisa.dtb"
		else
			echo "DIFFERS from board/lisa/lisa.dtb -- use DTB=dtb/lisa/dtb for builds"
		fi
	fi
fi

say "done"
echo "Keep backup/ private: it contains your IMEI and RF calibration."
echo "Next: docs/porting-plan.md, milestone 0/1."
