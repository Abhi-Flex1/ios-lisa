# ios-lisa — working notes

## Active handoff (2026-10-20 evening)

### Goal

Boot the ios-sweet iOS 16.7.16 (iPhone X `iPhone10,3` / D22AP) userland on a
Xiaomi 11 Lite 5G NE (`lisa`, SM7325 / Snapdragon 778G), then bring up as much
hardware as the reference port: home screen, touch, keys, Settings/CC, CPU
rendering; no GPU/radios at first.

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

Next: rebuild the CI kernel with 0082, repack the md0 image, and boot it. The
image should get past `SWEET GIC` and reach `SWEET CPU: ... came alive` /
`SWEET FB: AppleCLCD ...` / `SWEET init: hello`.

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

- Phone: connected, sitting on the XNU panic screen from 2026-10-20 19:46.
  Power-cycle it (hold Power ~10 s), then Vol-Down + Power to get back to
  fastboot before the next `fastboot boot`.
- Slot A: Android (untouched). Slot B: v3 diagnostic shim (TWRP backup in
  `backup/boot_b.img`). Active slot: A. The v4 diag and XNU runs used
  `fastboot boot` only; nothing was flashed.
- Repo: `main` includes patch 0082 and these notes (see the commit log). The
  `shim/out/` images are still the **pre-0082** kernels until CI finishes and
  `tools/lisa-build-images.sh` repacks them.

### Single next action

The phone is connected but on the panic screen; power-cycle to fastboot
first. **Everything below is `fastboot boot` only**; none writes a partition.
If an image is rejected, stop and ask before any flash.

1. After the CI kernel is downloaded and the images are repacked, run
   `fastboot boot shim/out/shim-boot-xnu-md0.img` — XNU + the mockfs init
   (`cpus=1`) with `sweetcntp=0`. Expected, in order: `EMBED`/`JUMP` from the
   shim; the XNU early log on the framebuffer; `SWEET GIC: virtual timer
   INTID 27`; **no** `Undefined kernel instruction`/`CNTP` panic; `SWEET CPU:
   requested=1 selected=1`; `SWEET CPU: cpu=0 ... came alive`; `SWEET FB:
   AppleCLCD 1080x2400 ...`; then `SWEET init: hello` / a PID digit /
   periodic alive lines. Photograph the last screen.
2. If it still panics at `_fiq_context_init` with `instr=0xd51be228`, the
   boot arg did not reach the kernel: stop and inspect the payload cmdline
   (`mkpayload.py`/the `boot_args` string), do not flash.
3. If step 1 stops before the init, try `shim-boot-xnu-md0-noufs.img` (same,
   without the `/sweet-ufs` node). `rd=md0` does not call
   `sweet_ufs_rootdev()`, so this is only isolation, not a likely fix.
4. Once step 1 reaches the init, step up: `-c4.img`, then `-c8.img`. The CI
   kernel has SMP patch 0065/0078 (PSCI CPU_ON, 8 cores).

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
