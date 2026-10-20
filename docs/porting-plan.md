# Porting plan: iOS 16 userland + XNU to lisa (SM7325)

This repository starts from [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet),
the only public project that boots an unmodified iOS 16 userland on a
Qualcomm Android phone. That port targets `sweet` (SM7150). lisa is a close
cousin: same GICv3, same 19.2 MHz timer, same UFS IP, same GENI/QUP blocks,
same "ABL leaves a splash framebuffer" boot model. The differences are real but
bounded: newer PMICs, a different touch transport, a different framebuffer
address, and a different virtual-timer INTID.

Nothing here is a one-shot job. The upstream project took hundreds of kernel
iterations; this plan is ordered so that every milestone produces something
observable on the phone, and so that a failure is attributable to one change.

## Milestone 0 — protect the phone (hardware, ~30 min)

1. Confirm the bootloader is unlocked (`fastboot getvar unlocked` → `yes`).
   Xiaomi requires the account-bound unlock; do not attempt EDL/exploit paths.
2. Boot OrangeFox **temporarily** (`fastboot boot recovery.img`) and back up at
   minimum `persist`, `modemst1`, `modemst2`, `fsg`, `fsc`, `boot`, `dtbo`,
   `vbmeta`. Keep them in `backup/` (gitignored). These hold the IMEI and RF
   calibration; losing them is not recoverable by reinstalling Android.
3. Run `tools/lisa-device-dump.sh` and record the phone's own DTB, RAM map,
   panel variant and firmware version in `NOTES.md`.
4. Decide explicitly about `userdata`: the iOS root will live there, which
   **erases Android's data**. That step is a separate, confirmed action much
   later; nothing before milestone 4 touches it.

## Milestone 1 — the shim boots on lisa (first hardware result)

Goal: camera-visible text on the phone, produced by our code, with no XNU.

```
BOARD=lisa shim/build.sh                     # empty ramdisk -> diagnostics
fastboot boot shim/out/shim-boot.img
```

What it must print/verify:

- CPU feature registers: 16K granule support, GIC system-register interface,
  no pointer auth.
- PSCI/SMCCC version and which calls TrustZone allows.
- SMP: `PSCI CPU_ON` for the secondaries, each reporting its MPIDR (expect the
  A55 cluster at 0x000–0x300, A78 at 0x400–0x700).
- GICv3 Group 1 interrupt from the **virtual timer INTID 27**.
- UFS register dump and a read-only SCSI READ of LUN 0.
- The framebuffer at `0xe1000000` is writable and scan-out is live.

Likely blockers, in order of probability:

1. Framebuffer not at `0xe1000000` after `fastboot boot` → find it from
   `cont_splash_region` in the phone's DTB / from ABL logs, or use the
   persistent-log approach from sweet and read it in recovery.
2. `fastboot boot` refuses the image (AVB / header) → the shim's boot.img is
   the same v2 format sweet uses; use the phone's own stock DTB and check
   `fastboot getvar current-slot`, `vbmeta` state.
3. Different timer INTID → the shim prints which INTID actually fires; adjust
   `shim/board.h` and `tools/mkadt.py`.

## Milestone 2 — XNU starts on lisa

1. Build the kernel via GitHub Actions (`.github/workflows/xnu.yml`). This Mac
   has only Command Line Tools, not Xcode; the CI path is the supported one.
   Fork the repo (public repos get free macOS minutes) and run:
   `gh workflow run xnu.yml -R YOU/ios-lisa`.
2. Generate the ADT and payload:

   ```
   python3 tools/mkadt.py shim/out/lisa.adt --board lisa --highmem
   python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/lisa.adt \
       shim/out/payload.bin --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1 ...'
   BOARD=lisa shim/build.sh shim/out/payload.bin
   ```

   (`kernel.development.sweet` is the upstream artifact name; the SWEET machine
   config is still the one the patches define. Renaming it is cosmetic and
   deliberately deferred.)
3. Boot and read the kernel console. The first goals are: platform expert
   matches, GIC/timer work at INTID 27, the 4 A55 cores come up, the physmap
   over the 4–6 GiB window is accepted, and the UFS driver attaches.
4. Reuse `tools/qemu-sweet.py` for kernel-only changes: QEMU virt with the same
   kernel catches most mistakes without a 4-minute phone boot cycle.

## Milestone 3 — storage and root

1. Build the iOS 16.7.16 (20H392, iPhone X `iPhone10,3`) HFS+ root from the
   IPSW with `tools/mkiosroot.sh` (Linux, `apfs-fuse` + `hfsprogs`; a Linux VM
   is fine). This is Apple's copyrighted content: never commit it.
2. Apply `tools/sweet-root-tweaks.py` (its header documents each change).
3. Flash the root image to `userdata` and boot with
   `rd=ufsroot0 ufsrw=1 rootrw=1`. This is the first destructive step.
4. Fix UFS 2.2/3.1 differences if the lisa unit's link comes up differently
   from sweet (the driver is the same IP; the PHY init sequence is yupik).

## Milestone 4 — userland on the screen

1. launchd + shared cache with the permissive AMFI/applekeystore stubs.
2. Display: `IOSurface` + `IOMobileFramebuffer` copy into the ABL framebuffer,
   presented as the iPhone X 1125x2436 canvas on the 1080x2400 panel.
3. Touch: port the Goodix GT9897T **SPI** protocol (downstream `goodix_core`
   is the reference) and feed HID digitizer events. Until then the phone is
   display-only and keys-only.
4. Buttons: PMK8350 PON for power/volume-down, PM7325 GPIO 6 for volume-up.
5. Battery: a static IOPMPowerSource first, PM7325 fuel gauge later.

## Milestone 5 — the rest

Wi-Fi/BT/cellular/audio/camera/GPS/SEP are explicitly out of scope for the
first working build (upstream does not have them either). Each is a separate
driver project. The honest definition of "as much as possible" for the first
release is: boots to the iOS home screen, unlocks, Settings/Control Center work,
touch and hardware keys work, no GPU (CPU rendering), no radios.

## What is already reusable from lisa's other ports

- **Mu-Silicium UEFI / Windows-on-lisa**: display init, UFS, USB, PMIC and the
  full memory map — useful as a cross-check, not as code (different boot model).
- **LineageOS device/kernel trees**: the authoritative DTS and driver sources
  for every peripheral above.
- **ios-sweet**: the whole XNU patch series, ADT generator, root builder,
  recovery log tooling and the iPhone X identity/activation approach. None of
  it is SM7150-specific except a handful of constants, which now live in
  `shim/board.h` and `tools/mkadt.py`.

## Tracking

`NOTES.md` is the live handoff: every boot, every crash, every CI run ID.
Update it before stopping. Do not put device dumps, serials, IPSWs or root
images in git.
