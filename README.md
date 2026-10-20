# ios-lisa

**Porting the ios-sweet bring-up to the Xiaomi 11 Lite 5G NE (`lisa`, SM7325).**

This is an experimental port of Apple's open-source XNU kernel (xnu-8796, the
iOS 16 generation) plus the unmodified iOS 16 userland to a Qualcomm Android
phone. It is not affiliated with Apple or Xiaomi. It is not a theme, a
launcher, or a VM.

The starting point is [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet),
which boots iOS 16.7.16 on the Redmi Note 10 Pro (`sweet`, SM7150). That project
is the reason this port is plausible at all: it solved the hard, non-obvious
parts (iBoot-compatible payload loading, a minimal Apple Device Tree, the
iPhone X identity/activation path, UFS root, HFS+, AMFI/keystore stubs,
IOSurface/IOMobileFramebuffer, HID). This repository adapts them to lisa.

## Status

**Scaffold only — nothing has booted on lisa yet.** The board abstraction, the
lisa ADT (Apple Device Tree) generator, the stock-DTB input and the device
inventory tooling are in place. The first hardware milestone is the diagnostic
shim (see [`docs/porting-plan.md`](docs/porting-plan.md)).

| Area | lisa |
|---|---|
| Diagnostic shim (CPU/GIC/PSCI/timer/UFS probe) | not run yet |
| XNU boots | no |
| iOS root / launchd / SpringBoard | no |
| Everything else (Wi-Fi, BT, cellular, audio, camera, GPU) | no |

The reference port's state (for calibration of expectations): home screen,
Settings, Control Center, touch, keys, CPU rendering at 20–30 fps, no GPU, no
radios, ~4 minute boot, security disabled. lisa aims for the same set first.

## Why lisa is a reasonable target

lisa (SM7325 / Snapdragon 778G) shares the parts that matter with sweet
(SM7150): GICv3 at the same addresses, a 19.2 MHz architected timer, the same
UFS host at `0x1d84000`, the same GENI/QUP serial engines, and the same
"bootloader leaves a splash framebuffer" model. The 1080x2400 AMOLED panel even
matches sweet's geometry, so the iPhone X 1125x2436 canvas and the whole display
path carry over. The differences — PM7325 PMICs, Goodix GT9897T on **SPI**
instead of I²C, framebuffer at `0xe1000000` instead of `0x9c000000`, virtual
timer INTID 27 instead of 19 — are enumerated in
[`docs/lisa-hardware.md`](docs/lisa-hardware.md).

## Layout

| Path | What |
|---|---|
| `shim/` | Bare-metal boot shim (C + asm) packed as an Android boot.img v2; `shim/board.h` holds the per-board constants |
| `board/lisa/` | Stock lisa device tree + provenance |
| `xnu/patches/` | The XNU patch series (upstream ios-sweet, applied in order by CI) |
| `.github/workflows/xnu.yml` | Kernel CI build (macOS runner) |
| `tools/mkadt.py` | Generates the Apple Device Tree; `--board lisa` (default) or `sweet` |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the shim payload |
| `tools/lisa-device-dump.sh` | Read-only phone inventory/backup helper |
| `tools/mkiosroot.sh`, `sweet-root-tweaks.py` | Build the HFS+ iOS root from an IPSW (Linux) |
| `docs/` | Hardware facts, porting plan, upstream notes |

## Quick start (once the phone is connected)

```
tools/lisa-device-dump.sh                 # identity, RAM map, DTB, boot backup
BOARD=lisa shim/build.sh                  # diagnostic shim
fastboot boot shim/out/shim-boot.img      # temporary; nothing is flashed
```

Requirements: unlocked bootloader, `adb`/`fastboot`, an aarch64 cross toolchain
(`aarch64-linux-gnu-gcc` or a clang/lld equivalent), `mkbootimg`, and Python 3.
The kernel build uses GitHub Actions because it needs a full Xcode; see
`docs/porting-plan.md`.

## Safety

- Nothing is flashed to boot/dtbo/vbmeta. Bring-up images are loaded with
  `fastboot boot` only.
- The iOS root goes into the **existing `userdata` partition** and erases
  Android's data. That is a late, explicit step, never automatic.
- Back up `persist`, `modemst1/2`, `fsg`, `fsc` first. They contain the IMEI
  and RF calibration and cannot be regenerated.
- Security is off in this design (permissive AMFI, no SEP, no data protection).
  Do not put personal data on a device running it.
- iOS itself, IPSWs and extracted root images are Apple's copyrighted works and
  are not distributed here.

## Credits

[dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) (the port this
is derived from), Apple's open-source xnu/HFS/IOHIDFamily/libpthread releases,
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) and
[ipsw](https://github.com/blacktop/ipsw), BearSSL, LineageOS device/kernel
trees for lisa, [Project-Silicium/Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium)
for the lisa DTB and UEFI memory map, and OrangeFox Recovery.

Licensed under Apache-2.0 (see `LICENSE`). The stock lisa DTB under
`board/lisa/` is a vendor artifact, not Apache-2.0; see its README.
