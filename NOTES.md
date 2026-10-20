# ios-lisa — working notes

## Active handoff (2026-10-20, initial scaffold)

### Goal

Boot the ios-sweet iOS 16.7.16 (iPhone X `iPhone10,3` / D22AP) userland on a
Xiaomi 11 Lite 5G NE (`lisa`, SM7325 / Snapdragon 778G), using the same
temporary `fastboot boot` model, and get as much hardware working as the
reference port has (home screen, touch, keys, Settings/CC, CPU rendering; no
GPU/radios at first).

### State: scaffold only, nothing booted on lisa yet

Done this session:

- Imported the complete ios-sweet tree (shim, 69 XNU patches, CI, tools, docs)
  as the starting point. Upstream log archived as
  `docs/upstream-sweet-NOTES.md`.
- Added `shim/board.h` (`BOARD_LISA` default, `BOARD_SWEET` baseline) and moved
  the framebuffer / GIC / timer INTID / UFS / IMEM constants into it.
- Made `shim/build.sh` board-aware (`BOARD=lisa|sweet`, `CROSS`/`CC`
  overrides, per-board stock DTB path).
- Made `tools/mkadt.py` board-aware (`--board lisa|sweet`; the `BOARDS` table).
  lisa defaults: GICD `0x17a00000`, GICR `0x17a60000`, virtual timer 27,
  framebuffer `0xe1000000`, UFS `0x1d84000`, kernel RAM `0x100000000` + 2 GiB.
- Added the stock lisa DTB (`board/lisa/lisa.dtb`, provenance in its README).
- Added `tools/lisa-device-dump.sh` (read-only identity/RAM/FDT/boot backup).
- Wrote `docs/lisa-hardware.md` (sourced hardware facts) and
  `docs/porting-plan.md` (milestones, blockers, what is reusable).
- Rewrote `README.md`, `AGENTS.md`; upstream `NOTES.md` archived.

Not done: no cross toolchain installed locally, no shim build yet, no CI run,
no contact with the phone yet (it was not connected: `adb devices` empty).

### Facts established from source, not from the phone

- lisa's stock DTB is at `board/lisa/lisa.dtb` (from Mu-Silicium). All fixed
  carve-outs and dynamic pools are below 4 GiB, so the 4–6 GiB window is a safe
  kernel-managed RAM choice. **Verify with the phone's `/proc/iomem`.**
- The splash framebuffer is `cont_splash_region` = `0xe1000000` + `0x2300000`.
  **Unverified on hardware after `fastboot boot`.**
- Touch is Goodix GT9897T on QUPv3 SE13 **SPI** (`spi@a94000`), IRQ GPIO 81,
  reset GPIO 105, rails L7C/L2C — a real difference from sweet's I²C GT9896.
- Keys: PMK8350 PON (power, volume-down), PM7325 GPIO6 (volume-up).
- Panel: 1080x2400 AMOLED, DSC command mode; BOE (`0x36`) or CSOT (`0x42`)
  variant selected by `msm_drm.dsi_display0`.
- The HackiOS "iOS 16.5 on Mi 11 Lite 5G" demo was `renoir` (SM7350), not lisa,
  and had no public code. Nothing to reuse there.

### The single next action

Connect the phone to this Mac (booted Android with USB debugging, or OrangeFox
with adb) and run:

```
tools/lisa-device-dump.sh
```

That answers, from the hardware: exact model/region, 6 vs 8 GiB and the real
DRAM top, the phone's own DTB vs `board/lisa/lisa.dtb`, and produces the
`boot/dtbo/vbmeta` backups. Then build the diagnostic shim and `fastboot boot`
it (milestone 1). Do not flash anything.

### Open questions for the user

1. Bootloader already unlocked? (`fastboot getvar unlocked`)
2. Is `userdata`/Android data expendable later? (Not needed until milestone 3.)
3. Which recovery is available/preferred (OrangeFox image on hand)?
4. Can we push this repo to `Abhi-Flex1/ios-lisa` and use GitHub Actions for
   the XNU kernel build? (`gh` is not installed here yet.)
5. Is there a Linux machine/VM available for the IPSW → HFS+ root step?
