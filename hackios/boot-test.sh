#!/bin/bash
# Boot a HackiOS boot image on lisa with `fastboot boot` (nothing is flashed)
# and say whether the XNU loader answered on USB.
#
# usage: hackios/boot-test.sh out/lisa-boot.img
#
# The phone must be in fastboot (Vol-Down + Power).  Expect, on the screen:
#   == XNULOADER v3 ==
#   display 1080 x 2400 at e1000000
#   platform redwood          (until platform_lisa exists; same SoC values)
# and over USB `fastboot getvar product` -> product: xnuloader.
set -e
IMG=${1:?usage: boot-test.sh path/to/boot.img}
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }

echo "== fastboot devices"
fastboot devices || true
fastboot getvar product 2>&1 | head -2

echo "== booting $IMG (nothing is written to the phone)"
fastboot boot "$IMG"

echo "== waiting for the loader (up to 60 s)"
for i in $(seq 1 30); do
	sleep 2
	p=$(fastboot getvar product 2>/dev/null | tr -d '\r' | sed -n 's/^product: //p')
	case "$p" in
	xnuloader) echo "loader is up (product: $p)"; exit 0 ;;
	"") ;;
	*) echo "still the bootloader (product: $p)" ;;
	esac
done
echo "loader did not answer; photograph the screen, then Vol-Down+Power back to fastboot" >&2
exit 1
