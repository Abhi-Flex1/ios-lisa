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

## Milestone 1 — the shim boots on lisa (first hardware result) — DONE 2026-10-20

Goal: camera-visible text on the phone, produced by our code, with no XNU.

```
BOARD=lisa shim/build.sh                     # empty ramdisk -> diagnostics
fastboot boot shim/out/shim-boot.img
```

Result: the shim runs and paints the red console. `fastboot boot` itself is
refused by this ABL for v1/v2/v3 (and even for the stock boot image/TWRP), so
the first run was flashed to the inactive slot B. The port then adopted
`ios-topaz`'s discovery: Xiaomi ABL wants **boot image v4** for `fastboot boot`
and **drops the v4 boot ramdisk**, so the payload is appended after `_end` in
the kernel Image. `tools/mkbootimg.py` and `shim/build.sh` implement that; the
v4 image is the next thing to try (non-destructive).

What it printed/verified:

- CPU feature registers: **TG16=1**, GIC system-register interface (`ICC_SRE=1`),
  no pointer auth, PARange 2 (40-bit).
- PSCI 1.1 / SMCCC 1.1 over SMC; CPU affinities `0x000–0x700` (4×A55, 4×A78).
- GICv3 Group 1 interrupt from the **virtual timer INTID 27** (the test ran;
  the first run then hit a shim cleanup bug on `CNTP_CTL_EL0`, fixed).
- UFS at `0x1d84000`: register dump, TEST UNIT READY, READ CAPACITY and a
  GPT parse of LUN 0 — all read-only and successful.
- The framebuffer at `0xe1000000` is writable and scan-out is live
  (`SPLASH base=E1000000 size=02300000`).

Result (v4, 2026-10-20 19:39): `VTIMER irqs=0x1E`, `SGI1 irqs=0x0A`,
`ENABLE=0x48000002`, `ICC ctlr=0x8400 grpen1=1`. `DONE` is one row below the
last visible console line (the shim console does not scroll). See `NOTES.md`.

## Milestone 2 — XNU starts on lisa — DONE 2026-10-20 21:45

**Status 2026-10-20 21:45:** XNU now runs **all the way into userspace** on
lisa. The v4 image boots past `_fiq_context_init` (CNTP fix, patch 0082),
matches lisa's `qcom,kryo670` CPUs (patch 0083), and brings up VM, IPC, IOKit
matching, `bsd_init`, `bsd_autoconf` and the net stack; the mockfs RAM-disk
root is mounted as `md0` and the mockfs `sweet-init` is `exec`ed as **PID 1**
(`*** SWEET userspace: init running as PID 1 ***`, photo `IMG_0719.HEIC`).
That proves exec, the user/kernel boundary, devfs and the console on lisa.

The earlier reading of "stops at `subsystem is initialized`" was wrong: the
fbcon is a **ring buffer** (newest lines just after the wrap point, i.e. at
the top of the screen) and the boot is **slow** (`dlil_init`/`ifnet_attach`
block until every dlil thread is scheduled; the skywalk self-tests take
seconds), so the earlier photos were simply taken too early. Details and the
exact log are in `NOTES.md`.

Remaining in this milestone: confirm the **plain** image (no `startup_debug`
boot arg) reaches the same point, then step `cpus=1` -> `4` -> `8` and check
the PSCI CPU_ON path, then move to Milestone 3 (real iOS root on `userdata`).

Historical note (2026-10-20 20:06, kept for context): the CNTP fix worked
(the v4 image boots past `_fiq_context_init` with no panic, reaches the
framebuffer `SWEET FB: AppleCLCD 1080x2400 ... 0xe1000000` and the platform
services). lisa's ADT CPU nodes are `compatible = "qcom,kryo670"`, but
`SweetCPU` only matched `qcom,kryo470`; the boot CPU therefore never registered
with IOCPU. Patch `0083-sweet-lisa-cpu-match.patch` adds the lisa match and
also disables the SM7150 early framebuffer console on lisa (`0x9c000000` is
RAM there; the real framebuffer is `0xe1000000`).

1. Build the kernel via GitHub Actions (`.github/workflows/xnu.yml`). This Mac
   has only Command Line Tools, not Xcode; the CI path is the supported one.
   Pushes to `xnu/patches/**` or a manual dispatch run it. The artifact is
   `xnu-kernel` (`kernel.development.sweet`); record the run ID in `NOTES.md`.
2. Build the ADT, payloads and v4 images in one step:

   ```
   tools/lisa-build-images.sh xnu/out-<run>/kernel.development.sweet
   ```

   It generates `lisa-hi.adt`, the `rd=md0` payloads for `cpus=1/4/8`, the
   no-UFS variant and the diagnostic image, and checks the v4 header plus the
   `SWEETXNU` magic at `0xd0000`. Every md0 image carries `sweettouch=0
   sweetkeys=0 sweetusb=0 sweetbattery=0 sweetcntp=0`: the first four opt out
   of sweet drivers that use sweet PMIC, QUP and TLMM addresses, while lisa's
   touch is SE13 SPI and its rails are PM8350C; `sweetcntp=0` skips the
   trapped physical-timer write. See `NOTES.md`. The mockfs init (the Mach-O from
   `tools/mkinit.py`) is served as `/sbin/launchd`, so this test does not need
   the iOS root or a wiped `userdata`. The first real root boot replaces it
   with `rd=ufsroot0`.
3. Boot and read the kernel console. The first goals are: platform expert
   matches, GIC/timer work at INTID 27, the boot A55 comes up, the physmap over
   `0x100000000..0x1ffffffff` is accepted, and the mockfs init prints. Then
   raise `cpus` and attach UFS.
4. Reuse `tools/qemu-sweet.py` for kernel-only changes: QEMU virt with the same
   kernel catches most mistakes without a phone boot cycle (the lisa payload is
   highmem and lisa-GIC-specific, so build the `--qemu` ADT variant for QEMU).

## Milestone 3 — storage and root

`docs/root-build.md` has the exact IPSW URL/hash, the three DMG members, the
range-extraction commands, the `mkiosroot.sh` invocation and the sparse/flash
steps.

1. Build the iOS 16.7.16 (20H392, iPhone X `iPhone10,3`) HFS+ root from the
   IPSW with `tools/mkiosroot.sh` (Linux, `apfs-fuse` + `hfsprogs` + root; this
   Mac has no passwordless sudo, so it cannot mount/copy as root; the running
   `FinnOS-dev` Parallels Arch VM is a candidate once SSH access and a larger
   disk are set up — see `NOTES.md`). This is
   Apple's copyrighted content: never commit it.
2. The D22AP DeviceTree (33 KiB) is already extracted locally to
   `research/ipsw-x/d22ap.adt` from the IPSW with `tools/remotezip.py` +
   `tools/adt.py unwrap`; `mkadt.py` now emits the real `/product` node
   (iPhone X identity for MobileGestalt). `research/` stays out of git; the
   recipe is in `docs/root-build.md`.
3. Apply `tools/sweet-root-tweaks.py` (its header documents each change).
4. Flash the root image to `userdata` and boot with
   `rd=ufsroot0 ufsrw=1 rootrw=1`. This is the first destructive step and
   needs confirmation immediately before the command.
5. Fix UFS 2.2/3.1 differences if the lisa unit's link comes up differently
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
