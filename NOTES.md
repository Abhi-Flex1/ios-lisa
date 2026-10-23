# ios-lisa — working notes

## Active handoff (2026-10-22)

### Decision: path A — APFS root via the UniXNU model

HFS+ is dead for iOS 16 (SSV/cryptexes need APFS). The root is now the
UniXNU `SHNGROOT` layout: a 1 MiB manifest plus the **unaltered whole-disk**
OS and SystemOS images from the IPSW, published by a native UFS window
driver as `IOMedia`; Apple's `apfs.kext` mounts them. No Linux host is
needed any more.

### Done today

1. **`tools/mkuserdata.py`** (new, validated): builds the manifest image.
   * `/Users/abhi/ios-lisa-work/ios16-root-20H392-lisa-shngroot.img`
     **8,380,219,392 B (7.80 GiB)**, sha256
     `2c2aca3feb7585c91b80ec6b50cc1888ac9315f4c77d981566de5dd902eabefa`.
   * OS window at `0x100000`, 5,635,081,728 B, sha256
     `6e87bfcaa8eca952e00b719f333d1f1060715a63566112267ad8730e1ed98906`;
     it is a GPT disk with one `Apple_APFS` partition
     (`7c3457ef-0000-11aa-aa11-00306543ecac`, LBA 34..11005985).
   * SystemOS window at `0x150000000`, 2,743,074,816 B, sha256
     `9cd738f3b0169055549df84ad6d8d13e50a2da39af618ce0522ca4e06df86849`;
     it is a **bare APFS container** (`NXSB` at byte 32), no GPT.
   * Manifest checksum and both MBR/GPT signatures verified in place.
   * Builder uses `hdiutil imageinfo` Total Bytes + `/dev/rdisk` reads;
     synthetic-DMG test proved manifest fields and window placement.
2. **iPhone X kernelcache** (`Firmware/...kernelcache.release.iphone10b`,
   18,204,358 B) fetched from the 16.7.16 IPSW; IM4P unwrapped with
   `tools/adt.py` to `kernelcache.d22` (50,937,884 B), thin arm64 slice in
   `/tmp/kernelcache-arm64`. It is **xnu-8796.142.1.703.8**; our kernel is
   **8796.141.3** (Darwin 22.6.0, same family).
3. **Prelink proof of concept** (`UniXNU/NativePrelink` `emit_prelink.py`,
   BSD): our kernel already has the `__PRELINK_*`/`__PLK_*` coalesced
   segments the tool needs. With the `__CTF` segment neutralised
   (filesize/section size 0) the tool parses; selecting
   `com.apple.filesystems.apfs` + `com.apple.iokit.IOStorageFamily` pulls in
   apfs, IOStorageFamily, corecrypto, AppleImage4, CoreTrust,
   AppleEffaceableStorage, CoreAnalyticsFamily, IOCryptoAcceleratorFamily,
   7 kernel interfaces, 6964 kernel bindings and 5172 component pointers.
   Output `/tmp/prelinked-diag.macho`, 54,992,896 B.
4. **Exactly one missing kernel symbol**: `_vfs_getvfs_with_vfsops`
   (0xfffffff00734c520). Disassembly shows it is `vfs_getvfs()` plus a
   check that `mount->mnt_op == vfsops` — our `_vfs_getvfs` uses the same
   fsid offsets (0xc0/0xc4) and `mnt_op` is at 0x28. A two-line shim is
   enough:
   `mount_t vfs_getvfs_with_vfsops(fsid_t *fsid, struct vfsops *vfsops)`
   in `bsd/vfs/vfs_subr.c`.
5. **Sparse prelink index ABI** is the other kernel requirement: the
   prelink copies only selected components, so `kalloc_type_view_parse`
   must walk the `__macho_list` index instead of assuming contiguous
   kext headers (UniXNU patch `xnu-10063.141.1-sparse-index.patch`;
   `_kalloc_sparse_prelink_index_version = 1` marker). Port to 8796's
   `osfmk/kern/kalloc.c`.
6. **IOStorageFamily is open source** (`apple-oss-distributions/
   IOStorageFamily`: IOMedia, IOBlockStorageDevice/Driver,
   IOGUIDPartitionScheme). UniXNU compiles it into the *native* kernel and
   prelinks only APFS; APFS's IOMedia imports then bind to the native
   implementation (`unique_kernel_binding`). Same plan here.
7. CI artifacts are downloadable again: the git credential helper holds a
   working token, used only against `Abhi-Flex1/ios-lisa` via the API.

### 2026-10-22 23:5x: FLASH VALIDATED on lisa

Flashing the 7.80 GiB raw image (`fastboot flash userdata`, 10 sparse parts,
3m15s, no `-S`) and booting `shim-boot-xnu-root.img` (kernel from run
`39795819658`) prints, on every mount retry (photos `IMG_0740/0741.HEIC`):

```
SWEET UFS: open: block0 53484e47524f4f54 ver 1 windows 2 image 7992 MiB bytes1024 00000000
SWEET UFS: window 0 "OS" off 0x100000 size 5374 MiB
SWEET UFS: window 1 "SystemOS" off 0x150000000 size 2616 MiB
```

`53484e47524f4f54` = "SHNGROOT": the flash wrote the image correctly and the
kernel's UFS read path returns real data.  The old "unknown Volume Signature:
0" was the swapped `img2simg` header, not UFS.  HFS still fails (expected:
APFS only).  The phone was powered off after the photos.

### 2026-10-23: HackiOS — a working SM7325 port exists (strategy pivot)

<https://hackios-web.vercel.app/en> -> `github.com/oosexgang`.  Two real
repositories (591 files in the kernel one), not vapour:

- `hackios-xnu-kernel`: XNU **8796.121.2** built from public source on Linux
  (theos cctools + clang + generated `iig` stubs, no Xcode), an EFI loader
  (`xnuloader/loader.c`), a Mu-Silicium UEFI port, and device drivers as
  overlay files.
- `hackios-xnu-userland`: init, injected libraries, launchd jobs and the
  **APFS image builder** + IPSW extraction.

Claims (README, with photos): iOS 16.5 userland on POCO X5 Pro 5G
(**redwood, SM7325 — the same SoC as lisa**), lock screen, home screen, apps,
touch, keys, 8 cores, Adreno 642L via Mesa, Wi-Fi (WCN6750), sound, camera,
APFS root on flash with writes.

Why this matters for lisa, verified in the tree:

- `xnu/files/bsd/dev/redwood_ufs.c` / `redwood_ufshc.c`: UFS host base
  **0x1d84000**, identical to ours.  The loader hands the controller over
  (`struct ufshc_loader`).
- `xnu/files/bsd/miscfs/apfs/`: their **own APFS VFS** (read/write,
  libdeflate).  No kernelcache prelink, no IOStorageFamily, no SHNGROOT
  manifest needed.
- `prebuilt/uefi/SILICIUM_UEFI.fd` + `xnuloader`: boot chain is
  `fastboot boot` of a UEFI image; nothing is flashed; the session runs from
  RAM and returns to the loader.
- Mu-Silicium already has **`Platforms/Xiaomi/lisaPkg`**,
  `Resources/DTBs/lisa.dtb` and `Configs/lisa.toml` — the UEFI side for our
  exact phone.
- lisa's stock DTB has `xiaomi_k9_touch` = **Goodix GT9897T** (fw
  `goodix_gt9897t_fw_k9d.bin`, CSOT/BOE variants), WCN6750 and
  `Adreno642Lv1`.  redwood's driver is Goodix GT9916, WCN6750, Adreno 642L:
  same vendor/SoC blocks, different touch chip (port, don't copy).
- Mu-Silicium `Resources/Configs/lisa.toml` has `uefi_fd base = 0x9FD00000,
  size = 0x200000` — **exactly redwood.conf's FD_BASE/FD_SIZE**, and both
  panels are 1080x2400.  So the boot-shim addresses carry over unchanged.
- Their run flow needs no flashing at all: boot image = UEFI + a resident
  loader; `xl enter` uploads the kernel (`xl run`), `xl ramdisk` pushes
  `system.apfs` into RAM, `xl screenshot`/`xl log` read it back over the
  loader's USB (fastboot protocol) link.
- `common/new-device.sh <codename> device.dtb` + `docs/PORTING.md` describe
  exactly how to add a device; `common/devices/redwood.conf` is the template.
- Licence: APSL 2.0 (Apple) for the kernel repository; no Apple binaries in
  git.

Consequence: HackiOS supersedes the prelink/IOStorageFamily/SHNGROOT driver
work below.  Proposed lisa port: build Mu-Silicium `lisaPkg` with their
`mu-silicium.patch` shim, generate `common/devices/lisa.conf` +
`lisa.platform.c` from `common/new-device.sh lisa dtb/lisa/dtb`, build their
kernel, boot with `touchscreen=0` first.  Needs a Linux build host (theos +
clang; EDK2 for the UEFI).

### 2026-10-23 12:xx: DECISION — pivot to HackiOS; CI builds the stack

User chose "pivot fully, GitHub Actions as the build host".  No local Linux
VM is used.  What exists now (committed):

- `hackios/pins.env` — upstream trees pinned: hackios kernel `8e61187`,
  userland `a79ff07`, Mu-Silicium `42fe563` (tree) but the UEFI port is made
  on `e51cd87` (HackiOS's `uefi/BASE`).
- `hackios/ci-fetch.sh` — exact-commit fetch.
- `.github/workflows/hackios.yml` — ubuntu-24.04: theos + Linux cctools
  (`L1ghtmann/llvm-project` `iOSToolchain-x86_64`, pinned release
  `main-update_3-eabca92`) + `iPhoneOS16.5.sdk`; then
  `xnu/apply.sh`, `xnu-deps/setup.sh`, `xnu-build.sh -k`.  Artifacts: kernel,
  loader, logs.
- `.github/workflows/hackios-uefi.yml` — Mu-Silicium @ `e51cd87` +
  `uefi/mu-silicium.patch` + `XnuLoader.[ch]`, `build_uefi.py -d lisa`.
  **Run 39939323999 succeeded**: `lisa-SILICIUM_UEFI.fd` 2,097,152 bytes
  (SHA256 `78d34dc3...`), `XnuLoader.obj` in the build log, plus Mu-Silicium's
  `lisa.dtb` (SHA256 `fae0b6fd...`).

lisa platform values, read from the stock DTB and Mu-Silicium's `lisaPkg`
memory map — and they equal redwood's, so `platform_redwood` is already
correct for lisa:

| value | lisa | redwood (loader.c) |
|---|---|---|
| GIC dist / redist | `0x17A00000` / `0x17A60000` | same |
| cores | 8, MPIDR shift 8, small 0-3 | same (`small_cores 0x0f`) |
| peripheral window | `0x00400000` + `0x3FC00000` | same |
| UFS host | `0x1D84000` (3 windows to `0x1D99000`) | same |
| framebuffer (GOP) | `0xE1000000` ("Display Reserved") | `0xE1000000` |
| UEFI FD | `0x9FD00000` + `0x200000` (`lisa.toml`) | same |
| payload base | `0xF0000000` (free RAM in lisa map) | same |

Boot image built locally with the prebuilt shim (redwood's shim has the same
FD/PAYLOAD addresses): `ios-lisa-work/hackios/out/lisa-boot.img`
(1,722,368 B, SHA256 `a28bb040...`).  It carries the lisa UEFI FD, Mu-Silicium
`lisa.dtb`, the prebuilt loader as a USB payload and the prebuilt ramdisk.

### 2026-10-23 13:1x: first hardware boot of the HackiOS stack

`fastboot boot out/lisa-boot.img` (1,722,368 B, SHA256 `a28bb040...`, the lisa
FD from run `39939323999`, `lisa.dtb`, the prebuilt shim and the prebuilt
payload with `loader.efi` 68,096 B + `usb`).  Nothing was flashed.

**Observation (user, on the phone):** the *Project Silicium splash appears* —
so the FD, the boot shim, `lisa.dtb` and the FD base `0x9FD00000` are all
correct.  But instead of the XNU loader, the phone booted its **Windows**
entry, which then errored, and the phone later came up in OrangeFox recovery.

**Cause (from the sources, not a guess):** the HackiOS patch called
`XnuLoaderMain()` only from `PlatformBootManagerUnableToBoot()`, which BDS
reaches *only when it has nothing to boot*.  lisa still carries a Windows
boot entry (the phone was dual-booted), so BDS booted it and the payload was
never touched.  The payload itself is well formed — verified by decompressing
the kernel: `XNUP` magic, size 68,184, entries `loader.efi` (68,096) and
`usb` (2).  The FD is LZMA-compressed, so "the strings are not in the FD" is
*not* evidence either way; the build log shows `XnuLoader.obj` compiled.

**Fix (committed 74f507b, `hackios/patches/0001-...`):** the pinned HackiOS
tree is now patched by *our* series, applied in CI after the upstream patch:

- `PlatformBootManagerAfterConsole()` calls `XnuLoaderMain()` when the payload
  at `0xF0000000` carries `loader.efi` — i.e. only for boots we started, so a
  payload-less FD still boots the installed OS normally;
- `XnuLoaderPayloadPresent()` and `StartPayloadLoader()` share one entry walk;
- the loader now prints on the framebuffer console: `XNU: loader.efi, N bytes,
  payload f0000000`, then `XNU: StartImage`, or
  `XNU: no loader.efi started (magic ...)` / `LoadImage failed` — so the next
  failure is visible in a photograph instead of being silent.

CI also greps `BootManager.obj`/`XnuLoader.obj` for those symbols before
uploading, which is the check that would have caught the first run.

### Next actions, in order

0. **Rebuild the UEFI in CI** (`hackios-uefi`, run from commit 74f507b or
   later), then repack and boot:
   ```
   cd ios-lisa-work/hackios
   UEFI_FD=/tmp/uefi-art/lisa-SILICIUM_UEFI.fd DTB=prebuilt/uefi/lisa.dtb \
     python3 mkxnuimg.py -p out/usb-payload.bin -o out/lisa-boot.img
   ios-lisa/hackios/boot-test.sh out/lisa-boot.img
   ```
   Expect the Silicium splash, then `XNU: loader.efi, 68096 bytes`, then the
   loader's own `== XNULOADER v3 ==` / `display 1080 x 2400 at e1000000`.
   Photograph early and late.
1. `xl run` the kernel from CI run `39941425135`
   (`mach.development.bcm2837`, SHA256 `3957a30c...`) with
   `XL_CMDLINE="touchscreen=0 cpufreq=1 bootcpu=7 cpus=8"`.
2. Fetch the iOS 16.5 20F66 `iPhone10,3` userland (`ios165/fetch.sh`, 7.4 GB)
   and build `system.apfs` for `xl ramdisk`.
3. The prelink/IOStorageFamily/SHNGROOT line (patches `0028`/`0084`) is
   superseded by HackiOS and is not pursued.

## Active handoff (2026-10-21 evening)

### Goal

Boot the ios-sweet iOS 16.7.16 (iPhone X `iPhone10,3` / D22AP) userland on a
Xiaomi 11 Lite 5G NE (`lisa`, SM7325 / Snapdragon 778G), then bring up as much
hardware as the reference port: home screen, touch, keys, Settings/CC, CPU
rendering; no GPU/radios at first.

Status: the kernel side is done through the SMP ladder (c1, c4, c8 all
confirmed on the phone). The **iOS root filesystem** is the remaining
milestone; see "Single next action" at the end of this file.

### 2026-10-21 21:4x: first UFS-root boot on lisa — UFS works, HFS does not

The iOS root image was built on macOS (native APFS via `hdiutil`, no Linux
host) with the new `tools/mkiosroot-macos.sh` + `tools/mkiosroot-macos-elevated.sh`:
`/Users/abhi/ios-lisa-work/ios16-root-20H392-lisa.img`, 16 GiB, 11 GiB used,
case-sensitive journaled HFS+ (signature `HX` at offset 1024). Verified inside
the image: `/sbin/launchd` is `root:wheel`, `/System/Library/Caches/com.apple.dyld`
hard-links the SystemOS cryptex cache, `/private/preboot/Cryptexes/{OS,App}` are
populated, logd stores are `_logd` (272) with `.migrated`, and
`/private/var/keybags/systembag.kb` exists. Flashed to `userdata` with
platform-tools **34.0.5** (37.0.1 fails on every image ≥ 4 GiB with
`Failed reading from userdata`; 34 also wants no `-S` for this image) and
booted `shim-boot-xnu-root.img` (`rd=ufsroot0 ufsrw=1 rootrw=1 ...`).

Result (photos `IMG_0729.HEIC`, `IMG_0730.HEIC`): the kernel finds and opens
the partition, then loops forever:

```
BSD root: ufsroot0, major 1, minor 0
hfs_ValidateHFSPlusVolumeHeader: unknown Volume Signature : 0
hfs_mount: hfs_mountfs returned error=22 for device unknown-dev
cannot mount root, errno = 19
mount (N) failed
```

So `sweet_ufs_rootdev()` + the GPT lookup work on lisa (it names `ufsroot0`),
but the volume header read came back **zero**. That is not a kernel bug: the
sparse image sent to `userdata` was malformed. `tools/img2simg.py` wrote the
chunk header with `chunk_sz` and `total_sz` **swapped** (`chunk_sz` must be a
block count, `total_sz` the byte size including the 12-byte header). The first
chunk in the image on disk read back as:

```
chunk type 0xCAC1  chunk_sz=33554444 blocks (128 GiB!)  total_sz=8192 bytes
```

so fastboot/ABL wrote a shifted, mostly zero stream: the HFSX header at
offset 1024 never landed at the start of the partition, which is exactly the
`unknown Volume Signature : 0` loop. The GPT LBA math in
`0028-sweet-ufs-root-device.patch` is correct: lisa's GPT LBAs are 4 KiB units
(`shim/ufs.c` prints `MiB=(last-first+1)>>8`, and the shim dump's
`userdata 0x2D4800/0xC30F` = 3.04 GiB start / 48.8 GiB), so no patch change is
needed there.

The writer is fixed (`chunk_sz=nblks`, `total_sz=12+len(payload)`, DONT_CARE
gets `total_sz=12`) and verified by expanding a synthetic image with an
independent spec parser: byte-identical round-trip, first chunk
`0xCAC1 sz=256` (1 MiB). The 16 GiB root image was then re-sparsified to
`ios16-root-20H392-lisa.simg` (11,900,256,284 bytes, 4096 chunks, all headers
consistent, block counts sum to 4,194,304 = 16 GiB, first RAW chunk has
`HX\x00\x05` at offset 1024). Next step: flash that image to `userdata`
(destructive, wipes the restored Android: ask first) and `fastboot boot
shim-boot-xnu-root.img`. Do not use `-S`; use platform-tools 34.0.5.

Android was then restored from `backup/` (boot/dtbo/vbmeta/vendor_boot);
the phone boots OrangeFox (the previous ROM's recovery), not Android, because
the `fastboot reboot recovery` boot-control block and/or the backed-up boot
image is a recovery. LineageOS 23.2 (20261020) was tried: its recovery boot
image uploads with `fastboot boot` but never enumerates adb, and a normal
reboot after flashing it falls back to fastboot. Not yet diagnosed.

### Milestone 1 DONE: the diagnostic shim runs on lisa

The shim boots and paints the red diagnostic screen. The first run reached the
GIC virtual-timer test and then took a synchronous exception; that was a bug in
the shim (it cleared `CNTP_CTL_EL0`, the EL1 physical timer, which this
platform traps) and is fixed. The rebuilt v4 image was seen on the phone on
2026-10-20 19:39 and is recorded below.

What the phone itself reported (photo of the red screen, 2026-10-20 18:08):

```
SPLASH base=E1000000 size=02300000
INITRD lo=AE113000 hi=...            (upper half covered by glare)
LOADER no SWEETXNU payload
MPIDR  0000000081000000             (Aff0=0; bit 24 = MT)
CPU    mmfr0=00101122 pfr0=11112222
CPU    parange=00000002 tg16=00000001
CPU    cntfrq=0124F800 sre=00000001
PSCI   ver=00010001 smccc=00010001
UFS    ver=00000300 cap=1587031F hce=00000001 hcs=0000010F
UFS    is=00000400 utrlba=9EE3B000 nutrs=00000020
UFS    MBR sig=0000AA55 type=000000EE; GPT EFI PART, 0x40 entries
       persist/persistbak/cust/super/logdump/minidump/rawdump/rescue/
       userdata/esp/win all parsed by name
GICD   was=00000053 now=00000053
GICR   base=17A60000 waker=00000000
ENABLE was=00000000 now=40000002
ICC    ctlr=00000400 grpen1=00000001
```

What the phone reported on the **v4** image (photo, 2026-10-20 19:39):

```
SPLASH base=E1000000 size=02300000
LOADER no SWEETXNU payload
MPIDR  0000000081000000
CPU    mmfr0=00101122 pfr0=11112222
CPU    parange=00000002 tg16=00000001
CPU    cntfrq=0124F800 sre=00000001
PSCI   ver=00010001 smccc=00010001
UFS    ver=00000300 cap=1587031F
UFS    hce=00000001 hcs=0000010F
UFS    is=00000400 utrlba=9EE3D000 nutrs=00000020
UFS    LUN0 lastlba=01D32FFF blk=00001000; READ ok
UFS    MBR sig=0000AA55 type=000000EE; GPT EFI PART, 0x40 entries
       persist lba=0x1000/0x40 MiB, persistbak 0x4100/0x40,
       cust 0xC000/0x80, super 0x8C000/0x2200, userdata 0x2D4800/0xC30F,
       esp 0xF0D700/0x14E, win 0xF22500/0xE10A; all parsed by name
GICD   was=00000053 now=00000053
GICR   base=17A60000 waker=00000000
ENABLE was=00000000 now=48000002
ICC    ctlr=00008400 grpen1=00000001
VTIMER irqs=0000001E other=00000000
SGI1   irqs=0000000A other=00000000
       pre: pend=0, isr=0, hppi=0x1B, tctl=5, last=0x1B
```

`DONE` is the next line below the last visible row; the shim console does not
scroll, so it was clipped in the photo. The v4 image **booted**, so lisa ABL
accepts header v4 and `fastboot boot` works.

### Milestone 3 DONE: XNU boots into userspace, `sweet-init` runs as PID 1

Photo `IMG_0719.HEIC` (2026-10-20 21:4x) of the **debug** image
`shim/out/shim-boot-xnu-md0-startupdbg.img` (SHA256 `63df5bc6...`, same
post-0083 kernel, only extra boot args `startup_debug=1 -show_pointers`)
shows the full chain working on lisa:

```
BSD root: md0, major 1, minor 0          <- mockfs RAM-disk root found
... "keyboard started"
... delayed_pages: initialized 0 free pages
VM Swap Subsystem is ON
No POST boot-arg set.
load_init_program: attempting to load /usr/appleinternal/sbin/launchd
load_init_program: attempting to load /sbin/launchd
load_init_program: attempting to load /sbin/launchd
*** SWEET userspace: init running as PID 1 ***
SWEET init: still alive                 (repeats every 5 s)
```

and, further down the (ring-buffered) screen, the kernel-side milestones:

```
SWEET HFS: hfs-627.100.6 registered
mcache: 1 CPU(s), 64 bytes CPU cache line size
mbinit: done [96 MB total pool size, (64/32) split]
SK: netagent is enabled by default for this platform
DLIL: running SUNIT16 self-tests ... PASSED
dlil_init: Waiting for all the created dlil kernel threads to get scheduled
           at least once.
dlil_init: All the created dlil kernel threads have been scheduled at least
           once. Proceeding.
SK[IO]: skmem_region_init
Skywalk: running self-tests ... (sk_copy*/sk_zero*/mencmp all PASSED)
bsd_autoconf: calling kminit
ifnet_attach: All kernel threads created for interface lo0 have been scheduled
              at least once. Proceeding.
ifnet_attach: ... gif0 ... / skip attaching stf0 using legacy TK model
Added memory device md0/rd0 (01000000/12000000) at FFFFFE00084CB0F
```

**Correction of the earlier "stops at `subsystem is initialized`" reading.**
The kernel was never stuck there. Two things were wrong with that
interpretation:

1. The fbcon (patch 0003) is a **ring buffer**: `fbcon_newline()` does
   `fbcon_row = (fbcon_row + 1) % fbcon_rows` and clears the new row and the
   next one. After a wrap the screen shows the last full screen in *circular*
   order, so the **newest** lines are the ones just after the wrap point (the
   top of the screen), and the **oldest** are at the bottom. The old photo's
   top lines (`BANK`/`IPC_PTHREAD_PRIORITY subsystem is initialized`) were
   *newer* than the bottom `subsystem is initialized` line.
2. Boot is **slow**: `dlil_init`/`ifnet_attach` block until every dlil
   kernel thread has been scheduled at least once, and the skywalk self-tests
   take seconds. The earlier photos were taken long before that point, so the
   screen legitimately still showed the IPC/IOKit phase.

With that understood, the post-0083 kernel runs the whole XNU bring-up on
lisa: VM, IPC, IOKit matching, `bsd_init`, `bsd_autoconf`, net init, **and
userspace**: `sweet-init` is `exec`ed as PID 1, opens `/dev/console`, and
writes to it. That means exec, the user/kernel boundary, devfs and the
console all work on lisa.

**Plain c1 confirmed (photo `IMG_0721.HEIC`, 2026-10-20 22:00):** the normal
image `shim/out/shim-boot-xnu-md0.img` (SHA256 `8f371b30...`, **no**
`startup_debug`/`-show_pointers`) shows the same thing, so the debug boot args
were not needed:

```
SWEET CPU: cpu=0 entered initCPU mpidr=0x0 EL1 IRQs=1
SWEET CPU: cpu=0 mpidr=0x0 came alive; SGI1 OK
Copyright (c) 1982, 1986, 1989, 1993 / The Regents of the University of
California. All rights reserved.
ARC Framework successfully initialized
using 5195 buffer headers and 4645 cluster 10 buffer headers
SWEET CPU: 1/1 CPUs initialized, SGI1 verified
dtrace_register_subsystem_strings: set subsystem 8 strings
calling mac_policy_init for SWEET AMFI
Security policy loaded: SWEET built-in Mobile File Integrity (SWEET AMFI)
SWEET AMFI: platform binary policy registered (0)
calling mac_policy_init for Sandbox
Security policy loaded: SWEET permissive sandbox stand-in (Sandbox)
SWEET Sandbox: permissive policy registered (0)
SWEET HFS: hfs-627.100.6 registered
mcache: 1 CPU(s), 64 bytes CPU cache line size
mbinit: done [96 MB total pool size, (64/32) split]
SK: netagent is enabled by default for this platform
DLIL: running SUNIT16 self-tests ... PASSED
dlil_init: Waiting for all the created dlil kernel threads to get scheduled
           at least once.
Skywalk: running self-tests ... (all PASSED)
bsd_autoconf: calling kminit
ifnet_attach: All kernel threads created for interface lo0 have been scheduled
              at least once. Proceeding.
ifnet_attach: ... gif0 ... / skip attaching stf0 using legacy TK model
Added memory device md0/rd0 (01000000/12000000) at FFFFFE00004C800
BSD root: md0, major 1, minor 0
serial keyboard started
VM Swap Subsystem is ON
No POST boot-arg set.
load_init_program: attempting to load /usr/appleinternal/sbin/launchd.development
load_init_program: attempting to load /sbin/launchd
*** SWEET userspace: init running as PID 1 ***
SWEET init: still alive
```

So the earlier "no `SWEET CPU` line" reading was also a photo-timing artefact:
the CPU lines are on the screen, just in the ring buffer's older half.

### Milestone 4: SMP — 4 CPUs on lisa (2026-10-20 22:05)
Photo `IMG_0722.HEIC` of the c4 image (`shim/out/shim-boot-xnu-md0-c4.img`,
SHA256 `43e2290c...`, `cpus=4`) shows the **SMP path working on lisa**:

```
SWEET CPU: requested=4 selected=4 (limit=8)
cpu_start() cpu: 0
SWEET CPU: cpu=0 entered initCPU mpidr=0x0 EL1 IRQs=1
SWEET CPU: cpu=0 mpidr=0x0 came alive; SGI1 OK
cpu_start() cpu: 1
SWEET CPU: cpu=1 CPU_ON target=0x100 entry_pa=0x10148d000 ...
SWEET CPU: cpu=1 PSCI CPU_ON rc=0
arm_cpu_init(); cpu 1 online
SWEET CPU: cpu=1 entered initCPU mpidr=0x100 EL1 IRQs=0
SWEET CPU: cpu=1 mpidr=0x100 came alive; SGI1 OK
SWEET CPU: cpu=2 PSCI CPU_ON rc=0
...
(ml_processor_register) cpu_id ... cluster_id 0 cpu number 0..3
```

`ml_processor_register` was called for logical CPUs 0, 1, 2 and 3, the PSCI
`CPU_ON` returned 0 for each secondary, every secondary reached
`initCPU` and answered the SGI1 self-test, and the boot continued into
`bsd_init` and the userspace init (`SWEET init: still alive`).

So the `cpus=N` boot arg works on lisa, the ADT's eight CPU nodes are picked
up, and the secondaries come up over PSCI. (An earlier reading of this photo
as "1/1 CPUs initialized" was a misread of the ring buffer: the requested/
selected line says `requested=4 selected=4`.)

Note the MPIDR encoding lisa uses: `reg` = `core << 8`, i.e. Aff1 = core
(0x000-0x700), which is what `tools/mkadt.py` emits for lisa and what the
shim's `MPIDR` (Aff0=0, bit 24 = MT) is consistent with.

### Milestone 2: XNU boots to the GIC/timer, then panics on CNTP

The next `fastboot boot shim/out/shim-boot-xnu-md0.img` (photo 2026-10-20
19:46) got past the shim handoff and into XNU:

```
init initialized
erp: mode specified: 00000003
init: zs_screen: b=E1000000, w=00000438, h=00000960, r=000010E0, f=00000000
pe_arm_init_interrupts: args: 0xffffffe0007b6a730
pe_arm_map_interrupt_controller: soc_phys:  0x10000000
pe_arm_map_interrupt_controller: failed to find the interrupt-controller.
pe_arm_init_debug: failed to find cpu-debug-interface
SWEET GIC: virtual timer INTID 27
panic(cpu 0 caller 0xfffffe0007ad6490): Undefined kernel instruction:
      pc=0xfffffe00074f1348 instr=0xd51be228 @sleh.c:951
handshake structure not initialized
```

Reading it precisely:

- `0xd51be228` disassembles to `msr CNTP_CTL_EL0, x8`. `sleh.c:951` is only
  the undefined-instruction panic site; the faulting function is
  `_fiq_context_init`. Its link-time `msr CNTP_CTL_EL0` is at
  `0xfffffe0007491348`; the panic PC is `0xfffffe00074f1348`, i.e. the kernel
  is running with a **+0x600000 slide**. The lisa secure monitor traps EL1
  accesses to `CNTP_CTL_EL0` (the shim hit the same trap at image offset
  `0x23b8`); the trap arrives as an undefined instruction, so XNU panics.
- `_enable_virtual_timer()` in `osfmk/arm64/machine_routines.c` writes
  `CNTV_CTL_EL0` (needed) and then `CNTP_CTL_EL0 = IMASKED` as a precaution.
  XNU uses the virtual timer; the physical timer write is optional. New patch
  `xnu/patches/0082-sweet-lisa-cntp.patch` adds a `sweetcntp` boot arg
  (default 1, upstream behaviour); lisa images pass `sweetcntp=0`.
- The interrupt-controller message is **not** the panic and is not
  lisa-specific: `pe_arm_map_interrupt_controller()` calls
  `SecureDTFindEntry("interrupt-controller", "master", ...)`, while both our
  ADT and upstream sweet's `mkadt.py` emit an empty `interrupt-controller`
  property. The caller ignores the return value, and sweet boots with the
  same message. Do not change the GIC node to chase this; the sweet GIC path
  maps `/arm-io/gic` itself and already works (`INTID 27`).
- `pe_arm_init_debug: failed to find cpu-debug-interface` is expected: lisa
  has no Apple debug interface node.

Rebuilt: CI run **39470689617** (commit `2c6fa4a`, 5m59s) produced
`kernel.development.sweet` SHA256 `7d3daff54e7678cd8ff518eb599f1942f12fb7ec1bfe2e8d45e24c9b8c093cbb`.
Disassembly of the new `_fiq_context_init` shows `PE_parse_boot_argn("sweetcntp",
...)`, then `cbz w8` skips the `msr CNTP_CTL_EL0` when the value is 0.
`tools/lisa-build-images.sh` repacked the v4 images on 2026-10-20 20:05;
`shim-boot-xnu-md0.img` SHA256
`c8bc529eea7b2b3b9b318745e85b02fcca698dfd46d47bf47516c7208a1e6b23`, and its
payload cmdline ends `... sweetbattery=0 sweetcntp=0`. **Not booted yet.**

Next: power-cycle the phone to fastboot and boot it. Expected: get past
`SWEET GIC` and reach `SWEET CPU: ... came alive` / `SWEET FB: AppleCLCD ...`
/ `SWEET init: hello`.

### 2026-10-20 20:06 boot: CNTP fixed, stops at `subsystem is initialized`

Photo `IMG_0716.HEIC` (2026-10-20 20:06) shows the `c8bc529...` image
(`sweetcntp=0`) got **past** the CNTP write with **no panic**. Visible order:
`SWEET AKS`, `SWEET WDT`, `SWEET SURF`, `SWEET HID`, `SWEET BATTERY`, then:

```
SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0xe1000000, default surface 1, presented as 1125x2436
...
VM bootstrap done: 85 maps, 165 entries and 501 holes left
IOKit IOND ownership ENABLED
  subsystem is initialized
```

The last line is one of XNU's `BANK`/`ATM`/`IPC_PTHREAD_PRIORITY subsystem is
initialized` strings; `subsystem is initialized` is the tail visible. There is
**no `SWEET CPU` line**. Patch 0003's fbcon wraps to the top instead of
scrolling, but the top still shows `apple_log`, so nothing printed after the
last visible line: the kernel is stopped there, not merely scrolled past.

**Root cause (most likely, to be confirmed by the next boot):** lisa's ADT
CPU nodes use `compatible = "qcom,kryo670"` (`tools/mkadt.py` board row), while
`SweetCPU`'s `IONameMatch` in `iokit/KernelConfigTables.cpp` only listed
`qcom,kryo470` (the SM7150 name). The boot CPU nub therefore never starts:
`SweetCPU::start()` is what calls `ml_processor_register()` /
`processor_start()`, prints `SWEET CPU: requested=...`, and publishes
`gIOAllCPUInitializedKey`. Without it the boot has no IOCPU for CPU 0 and
stops after the last IPC/IOKit message. With `cpus=1` only CPU 0 gets a
`logical-cpu-id`; the other 7 nubs return false, so `startAll` should wait for
exactly 1 and then start the boot CPU.

New patch `xnu/patches/0083-sweet-lisa-cpu-match.patch`:

- adds a second `SweetCPU` match for `qcom,kryo670`;
- defines `SWEET_LISA` in `pexpert/pexpert/arm64/SWEET.h`;
- skips the SM7150 early framebuffer (patch 0010/0012 hard-code
  `0x9c000000`) on lisa. On lisa `0x9c000000` is **system RAM**; the real
  framebuffer is `0xe1000000`. The early marks were invisible and the
  `start.s` mapping changed RAM to write-combining. The ADT-driven fbcon
  (`0xe1000000`) remains the visible console.

`0083` was generated and `git apply --check`ed on a tree with the existing
series; it is **not built yet**. Next: CI, repack, boot the c1 image.

**CI skip and corrected context (2026-10-20 20:26):** the first push
(commit `3ae05f8`) triggered run `39474725533`, which built successfully but
**skipped `0083`**:

```
Skipping patch .../0083-sweet-lisa-cpu-match.patch (already upstream,
previously applied, or malformed): error: patch failed:
iokit/KernelConfigTables.cpp:47
```

The cause is patch `0038-sweet-applekeystore.patch`, which inserts the
`AppleKeyStore` entry immediately after the `qcom,kryo470` entry. My first
hunk expected `#endif` to follow the SweetCPU entry. The downloaded
`xnu-kernel` therefore still contains only `qcom,kryo470`; do not boot it.
`0083` was regenerated against the actual fully-patched source in the
`xnu-buildtree` artifact from run `39474725533` (which includes every patch
except the skipped `0083`), so the insertion now lands between the SweetCPU
entry and `AppleKeyStore`. A new CI run is required.

**Rebuilt (2026-10-20 21:09):** run `39478509411` (commit `bfdf87d`) succeeded
in 8m10s. Kernel SHA256
`170e28dee8a8d804301a79b6e8c4186ed73590deb1a36da684d141f06142dd73`; unlike the
previous artifact, `strings` contains **both** `qcom,kryo470` and
`qcom,kryo670` entries. Repacked with `tools/lisa-build-images.sh`:

| image | SHA256 |
| --- | --- |
| `shim-boot-xnu-md0.img` (c1) | `8f371b30a80753441db1d7f4aa47cdfbe8ae27366071545cd4cca0061c7107fc` |
| `shim-boot-xnu-md0-c4.img` | `43e2290c136b48b05218967fb1c7472df1c19da5842c8b6895d5a12d2ee39a02` |
| `shim-boot-xnu-md0-c8.img` | `e77c11abaaacb05ef9c6e1e010029dea8fe70143960797392052783a7e76c429` |
| `shim-boot-xnu-md0-noufs.img` | `d15bed26908e592d1a8d2fd5f47df93261b874e8bd04869f0e336b002892c9b4` |

Next test: `fastboot boot shim/out/shim-boot-xnu-md0.img` (cpus=1).

Blue panic (before the fix): `STAGE gic vtimer`, `ESR 20000000`,
`ELR A00023B8`, `FAR 0`, `SPSR 600003C5` = `msr CNTP_CTL_EL0` at image
offset 0x23b8. Fixed in `shim/shim.c::irq_window()`: only clear the timer that
was armed (`CNTV` for the tests; `CNTP` is trapped here and XNU uses `CNTV`).

### How the shim got onto the phone

`fastboot boot` is refused by this unit for every format tried, including the
phone's own stock `boot_a`, the official lisa TWRP image, and a boot v3 image.
The bootloader then marks the active slot unbootable and drops to fastboot.
Recovery from that state: `fastboot set_active a` (reboots Android) — verified.

Workaround used for v3: flash the shim to the **inactive** slot B, set active
B. Slot A (Android) stayed untouched and was restored afterwards with
`fastboot set_active a`. `backup/boot_b.img` holds TWRP (the old slot-B
image) and `backup/boot_a.img` holds Android; both are git-ignored. The v4
images need none of this: `fastboot boot` loads them directly, as shown
above.

### CRITICAL: boot image v4 (from the `ios-topaz` port)

`MakrSas/ios-topaz` (iOS 16 on Redmi Note 12 4G, SM6225) documents the same
Xiaomi ABL wall and the fix:

- Xiaomi ABL **ignores boot image v1/v2**; `fastboot boot` needs **v4**.
- With v4 the ABL **drops the boot-image ramdisk** and only passes
  vendor_boot's, so the XNU payload must be **appended to the kernel Image at
  the first 4K boundary after `_end`** and `image_size` grown to cover it.

Implemented here but **not yet tested on lisa**:

- `tools/mkbootimg.py` now writes v4 (and still v1/v2/v3).
- `shim/build.sh` packs lisa as v4 and, when given a payload, appends it after
  `_end` (empty ramdisk), like topaz.
- `shim/loader.c` looks for `SWEETXNU` at `ALIGN(_end, 4096)` first and falls
  back to scanning the ABL initrd (with the topaz copy-down path).
- `shim/dtb_blob.S` embeds the phone's live DTB, so `SPLASH`/payload parsing
  does not depend on x0 if ABL hands over nothing useful.

The next phone test is therefore **non-destructive**: `fastboot boot
shim/out/shim-boot.img` (v4). If ABL accepts it, nothing is flashed and a reset
returns to Android on slot A.

### Boot image formats tried on lisa

| Format | How | Result |
| --- | --- | --- |
| v2 + DTB section, base 0 | `fastboot boot` | `Failed to load/authenticate boot image: Load Error` |
| v1 + appended DTB, base 0x10000000, 2K page | `fastboot boot` | same error |
| v1 + appended DTB, base 0 | `fastboot boot` | same error |
| v3, no DTB | `fastboot boot` | same error |
| v3, no DTB | **flash boot_b + set_active b** | **works** (red diagnostics) |
| v4, no DTB, no signature | `fastboot boot` | **works** (2026-10-20 19:39; no flash) |

Stock `boot_a` (v3) and the official TWRP image also fail `fastboot boot`, so
this is an ABL policy, not our image syntax.

### Hardware facts confirmed from the phone

- RAM (live FDT `/memory`): `0x80000000+0x39700000`, `0x180000000+0x100000000`,
  `0xc0000000+0xc0000000` (8 GiB). `0x100000000..0x1ffffffff` is contiguous RAM.
- Splash: `cont_splash_region` `0xe1000000` + `0x2300000`, 1080×2400 BGRA.
  The live FDT is authoritative; the stock vendor_boot base DTB says
  `0xea600000` (different carve-out, not the ABL splash used at boot).
- GICv3: GICD `0x17a00000`, GICR `0x17a60000` + `0x100000`, stride `0x20000`.
- Timer: 19.2 MHz (`0x124f800`), PPIs 13/14/11/12 → INTID 27 virtual, 30
  non-secure physical. `CNTP_CTL_EL0` from EL1 is **trapped** on lisa.
- PSCI 1.1 / SMCCC 1.1 over SMC. CPU affinities `0x000–0x700` (4×A55,
  4×A78), all with the 16K granule (TG16=1) — no Gold-only workaround needed.
- UFS at `0x1d84000` is live and readable from the shim; GPT parsed. Android
  GPT includes `esp` and `win` (Windows-on-ARM leftovers, expendable).
- IMEM restart reason at `0x146aa65c` (DT `restart_reason@65c`). PSCI reset
  currently re-enters slot B when it is active; use Vol-Down + Power to force
  fastboot after a test.

### XNU kernel built (2026-10-20 16:53 UTC)

The imported patch series builds unchanged for `MACHINE_CONFIG=SWEET`:

- run <https://github.com/Abhi-Flex1/ios-lisa/actions/runs/39459918522>,
  job `build`, conclusion `success` (started 16:43:17Z, finished 16:53:48Z).
- artifact `xnu-kernel` id `12282303086`, 60,001,284 bytes; unpacked to
  `xnu/out-39459918522/`.
- `kernel.development.sweet`, 16,839,008 bytes
  `sha256 eec89fdf75f6d7bbbee42f9277598ce57e36316db861b6e2eb47226e243a024b`.
- build command line contains `-DARM64_BOARD_CONFIG_SWEET`, `-DMOCKFS`,
  `-DSWEET_HFS`, `-DCURRENT_MACHINE_CONFIG_LC=sweet`.

The 11 `error:` lines in the log are the build script skipping optional
blacktop patches (TrustCache/iobuffermemd/skywalk/syntax_checker), not compile
errors; the kernel and `xnu-buildtree` artifacts uploaded successfully.

### lisa payload built (not yet booted)

```
python3 tools/mkadt.py shim/out/lisa-hi.adt --board lisa --highmem
python3 tools/mkpayload.py \
    xnu/out-39459918522/kernel.development.sweet \
    shim/out/lisa-hi.adt shim/out/payload-md0-c1.bin \
    --ramdisk /tmp/sweet-init \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 \
               -enable_kprintf_spam -noprogress rd=md0 \
               sweettouch=0 sweetkeys=0 sweetusb=0 sweetbattery=0'
BOARD=lisa shim/build.sh "$PWD/shim/out/payload-md0-c1.bin"
```

All of the above is one command now:

```
tools/lisa-build-images.sh xnu/out-39459918522/kernel.development.sweet
```

It regenerates the ADT, the diag image, the c1/c4/c8 payloads and the no-UFS
variant, then verifies the v4 header and the `SWEETXNU` magic at `0xd0000`.

Every md0 image also carries `sweettouch=0 sweetkeys=0 sweetusb=0
sweetbattery=0`. The **touch** driver is the one that cannot work on lisa: it
uses sweet's SE7 I2C at `0xa84000` and TLMM/NORTH at `0x03900000`, while
lisa's touch is **SE13 SPI** at `0xa94000` on **TLMM `0x0f000000`** and its
rails are **PM8350C**. The **keys** driver uses the same SPMI blocks as lisa
(`0xc440000`, `0xc40a000`, `0xe600000`) and is read-only, but its volume-up
path is PMK8350 GPIO2 rather than lisa's PM7325 GPIO6, so it is off too. The
USB probe is a separate case: its DWC3 `0xa600000` and QSCRATCH `0xa6f8800`
match lisa, but it also touches `0x88e2000` as the QUSB2 PHY, and on lisa
that is the **EUD mode-manager** window; lisa's USB2 PHY is `0x88e3000`.
`sweetusb=0` must stay until the probe's PHY base is board-conditional. The
battery path is PM6150-specific and lisa's is PM7325. Note the call sites:
`sweet_keys_init()`/`sweet_touch_init()` are called from `sweet_ufs_init()`,
which only `rd=ufsroot0` reaches, so they are not on the md0 path at all; the
USB probe (`unix_startup`) and the IOKit battery service are what run on
every boot. The root boot further down is where the touch/keys opt-outs
matter most. The md0 first boot therefore exercises only the platform expert,
GIC/timer, SMP, fbcon and the display service. Enable one at a time once the
matching lisa driver exists (`sweettouch=1`, `sweetkeys=1`, ...).

`/tmp/sweet-init` was built from `tools/sweet-init.S` with
`clang -target arm64-apple-ios16.0 -c` + `tools/mkinit.py` (16,635 bytes).
`MOCKFS` serves that executable as `/sbin/launchd`, so `rd=md0` proves kernel →
UFS-less root → exec → console **without touching userdata**.

- `shim/out/payload-md0-c{1,4,8}.bin` 16,630,192 bytes: 11 segments, entry
  `0xfffffe000748b488`, ADT `RAMDisk` = `0x1024c8000+0x8000`, ADT 12,652
  bytes (real `/product` included).
- `shim/out/shim-boot-xnu-md0.img` 17,494,016 bytes, v4, kernel_size
  17,482,160, payload at Image offset `0xd0000` (verified byte-for-byte);
  `cpus=1`.
- `shim/out/shim-boot-xnu-md0-c4.img` and `-c8.img`: same payload/ADT with
  `cpus=4` / `cpus=8`. The CI kernel includes `0065`/`0078` SMP (PSCI
  CPU_ON, 8 cores); `cpus=1` is still the first test.
- `shim/out/shim-boot-xnu-md0-noufs.img`: `cpus=1`, ADT without the
  `sweet-ufs` node. Note `rd=md0` never calls `sweet_ufs_rootdev()` — the
  function only runs for `rd=ufsroot0` — so this is belt-and-braces
  isolation, not a likely fix. `sweet_ufs_init()` and its persistent
  `sweetlog` UFS writer are also called only from `sweet_ufs_rootdev()`, so
  an md0 boot cannot write `userdata`; the console ring stays in memory.
- `shim/out/shim-boot-diag.img` 860,160 bytes, v4 diagnostic (no payload).
- `shim/out/shim-boot.img` is whatever was built last (build.sh overwrites
  it); always use the explicit names above.

The loader locates the payload at the **runtime** `_end` (the C reference
compiles to PC-relative `adr`), not by comparing the header's absolute
`image_size` with a runtime address.  The first version of the check did the
latter and would have rejected the valid payload.

### Milestone 4 DONE: 8 CPUs (c8) boot on lisa

Boots `shim/out/shim-boot-xnu-md0-c8.img` (SHA256
`30c15c938c9b214908d6553b67130e9399b2c0ee7a1b0c5931d12827c754b590`, payload
SHA256 `fe95291a...`, kernel CI `39478509411` SHA256 `170e28de...`) on
2026-10-21 17:12 with `fastboot boot` only. Photos `IMG_0725.HEIC`,
`IMG_0726.HEIC`, `IMG_0727.HEIC` (read with `tools/lisa-ocr.sh`).

All eight cores came up, including the four A78s at MPIDR Aff1 0x400-0x700:

```
SWEET CPU: 8/8 CPUs initialized, SGI1 verified
SWEET CPU: cpu=7 CPU_ON target=0x700 entry_pa=0x10148d000 context=7
SWEET CPU: cpu=7 PSCI CPU_ON rc=0
SWEET CPU: cpu=7 entered initCPU mpidr=0x700 EL1 IRQs=0
SWEET CPU: cpu=7 mpidr=0x700 came alive; SGI1 OK
SWEET CPU: cpu=6 CPU_ON target=0x600 ... rc=0, mpidr=0x600
SWEET CPU: cpu=5 CPU_ON target=0x500 ... rc=0, mpidr=0x500
SWEET CPU: cpu=4 CPU_ON target=0x400 ...
SWEET CPU: cpu=3 ... mpidr=0x300
SWEET CPU: cpu=2 ... mpidr=0x200
SWEET CPU: cpu=1 ... mpidr=0x100
acache: 8 CPU(s), 64 bytes CPU cache line size
BSD root: md0, major 1, minor 0
*** SWEET userspace: init running as PID 1 ***
SWEET init: still alive      (repeated; 30 s heartbeat)
```

Observed (not inferred):

- PSCI `CPU_ON rc=0` for every secondary 1..7; no panic, no
  `NOT alive` / startup timeout.
- `entered initCPU mpidr=0xNNN` prints the **hardware** MPIDR read from
  `MPIDR_EL1`, and it matches the DT `reg` for each core: 0x100-0x300 (A55)
  and 0x500-0x700 (A78). This confirms lisa's A78 cluster is a flat Aff1 range
  `core<<8`, so the `reg = core << 8` in `tools/mkadt.py` is correct as-is for
  all 8 cores, and that MPIDR 0x400 is a real core, not a hole.
- The `SWEET CPU: 8/8 CPUs initialized, SGI1 verified` line and
  `acache: 8 CPU(s), 64 bytes CPU cache line size` confirm XNU sees 8 CPUs.
- One `ml_processor_register` line was legible in the photos
  (`ml_processor_register>cpu_id 0xfffffe24d689f200 cluster_id 0 cpu` and
  `pset_find(cluster_id=0) returned pset 0`), i.e. XNU parsed the ADT as a
  single homogeneous SMP cluster, matching the `cluster-id = 0` /
  `cluster-type = CLUSTER_TYPE_SMP` that `tools/mkadt.py` emits for every
  core. Only one such line survived the ring-buffer wrap, so the other
  seven were **not** individually confirmed.
- Userspace came up normally: launchd load attempt, `skywalk` self-tests
  PASSED, `HFS: hfs-627,100,6 registered`, `BSD root: md0`, and
  `sweet-init` running as PID 1 with the 30 s heartbeat.
- The c8 image is the **rebuilt** one: the init heartbeat is 30 s (the `30`
  timeout constant is at payload ramdisk offset `0x4b0`), not the old 5 s.

Observation, not a conclusion: the screen never showed a panic and the init
heartbeat kept ticking in `IMG_0727.HEIC`, so the run was healthy at the time
of the photo. The c8 image was **not** re-verified with a second boot.

### D22AP `/product` node extracted (no full IPSW)

The only missing piece of the ADT was `/product`. It lives in the iPhone X
DeviceTree, 33,719 bytes inside the 6.17 GB IPSW. `tools/remotezip.py` fetched
just `Firmware/all_flash/DeviceTree.d22ap.im4p` with HTTP range requests
(CRC ok), and `tools/adt.py unwrap` (after `brew install lzfse`) produced
`research/ipsw-x/d22ap.adt` (182 KiB). `mkadt.py` now emits the real 63-prop
`/product` node (`product-name = iPhone X`, etc.) and the ADT is 12,600 bytes;
the c1/c4/c8 payloads/images were rebuilt with it. `research/` is gitignored;
the IPSW URL, member names and rebuild recipe are in `docs/root-build.md`.

The root image itself still needs a Linux host with root (`apfs-fuse` +
`hfsprogs`): this Mac has no passwordless sudo, so it cannot preserve
root/272 ownership or loop-mount the HFS+ image. There **is** a running Arch
Linux Parallels VM, `FinnOS-dev`, at `10.211.55.6`: sshd is up, the user is
`abhi`, Parallels Tools is not installed, and host-key auth is not set up
(`ssh abhi@10.211.55.6` answers `Permission denied (publickey,password)`).
Its 32GB disk is also too small for the 7.4GB DMGs + 16GB root image + temp.
To use it, add the Mac's `~/.ssh/id_ed25519.pub` to the guest's
`authorized_keys` (or provide the password) and attach a second ~40GB disk.
Do not stop or reconfigure the running VM without asking. The kernel payload
does not depend on the root image.

### Current machine/phone state

- Phone: running the **c8 XNU image** (8 CPUs, `sweet-init` as PID 1), booted
  2026-10-21 17:12 via `fastboot boot` only. Photos `IMG_0725.HEIC`,
  `IMG_0726.HEIC`, `IMG_0727.HEIC`. Not in fastboot; `fastboot devices` is
  empty. Power-cycle it (hold Power ~10 s), then Vol-Down + Power for fastboot
  before the next `fastboot boot`.
- Slot A: Android (untouched). Slot B: v3 diagnostic shim (TWRP backup in
  `backup/boot_b.img`). Active slot: A. The v4 diag and XNU runs used
  `fastboot boot` only; nothing was flashed.
- Repo: `main` includes patch 0082 and the corrected
  `0083-sweet-lisa-cpu-match`. CI run `39478509411` built the kernel
  (SHA256 `170e28de...`). These are the **post-0083** images. Image SHA256s:
  c1 `8f371b30...`, c4 `4bee8ba5...`, c8 `30c15c93...`.

### Single next action

The phone is currently **running the c8 XNU image** (8 CPUs, `sweet-init` as
PID 1), not in fastboot. **Everything below is `fastboot boot` only**; none
writes a partition. If an image is rejected, stop and ask before any flash.

1. Done: post-0083 kernel (CI `39478509411`, SHA256 `170e28de...`) reaches
   userspace; `sweet-init` runs as PID 1 (photo `IMG_0719.HEIC`).
2. Done: plain c1 image confirmed (photo `IMG_0721.HEIC`).
3. Done: c4 image confirmed, 4 CPUs, PSCI `CPU_ON rc=0` for every secondary
   (photo `IMG_0722.HEIC`).
4. Done: **c8 image confirmed on lisa** (photos `IMG_0725/0726/0727.HEIC`):
   8/8 CPUs, `CPU_ON rc=0` for cores 1..7, hardware MPIDRs 0x100..0x700,
   `sweet-init` still running as PID 1. The SMP bring-up ladder is finished.
5. **Next real goal: the iOS root.** The mockfs RAM disk only proves the
   kernel; the phone still needs a real HFS+/APFS root
   (`docs/root-build.md`, needs the Linux host with `apfs-fuse` and
   `hfsprogs`). Order of work:
   a. Fix access to the `FinnOS-dev` VM (`10.211.55.6`): add the Mac's
      `~/.ssh/id_ed25519.pub` to the guest's `authorized_keys` (or use the
      password) and attach a second ~40 GB disk. Its 32 GB disk cannot hold
      the 7.4 GB DMGs + 16 GB root image + temp. Do not stop or reconfigure
      the running VM without asking.
   b. Build the root image on the Linux host and verify it (HFS+ mount,
      `launchd` present, ownership 0:272 preserved).
   c. Flash the root to `userdata`. **This erases Android and is destructive:
      get the user's explicit confirmation immediately before that command.**
6. Optional, before the root flash: re-boot the c8 image once more to confirm
   the run is repeatable (the c8 image was only booted once, on 2026-10-21).
   Cheap insurance, `fastboot boot` only.

The v4 diagnostic (`shim-boot-diag.img`) already passed on lisa; keep it for
rechecking the shim, but it is not needed before this XNU step.

Recovery: a failed `fastboot boot` can mark the active slot unbootable;
`fastboot set_active a` + `fastboot reboot` restores Android. If the phone is
stuck, Vol-Down + Power forces fastboot. The root boot (`rd=ufsroot0`) comes
after the root image exists; see `docs/root-build.md`.

### Open questions / approvals

1. **Licensing:** upstream `dipa-studio/ios-sweet` has no LICENSE; this repo
   currently says Apache-2.0. Decide before making the repo public.
2. Android `userdata` will eventually be erased for the HFS+ iOS root. That is
   destructive and still needs confirmation immediately before the flash.
3. The `win`/`esp` partitions are Windows-on-ARM leftovers and may be wiped if
   space is needed (user approved wiping Windows, not yet needed).
4. A Linux host with `apfs-fuse` + `hfsprogs` is still needed for the iOS root
   image. The running `FinnOS-dev` Parallels VM (Arch Linux, `10.211.55.6`,
   user `abhi`) is the candidate; it needs the Mac's
   `~/.ssh/id_ed25519.pub` in the guest (or the password), plus a second
   ~40GB disk for the DMGs and image. Ask before stopping/reconfiguring it.
