# lisa hardware facts (SM7325)

Everything below is for the **Xiaomi 11 Lite 5G NE / 11 Lite NE 5G / Mi 11 LE**,
codename `lisa`, Qualcomm SM7325 (Snapdragon 778G). It is not the older
"Mi 11 Lite 5G" (`renoir`, SM7350/780G) — the HackiOS demo that circulated in
October 2026 was on that other phone, and no code was published for either.

Sources:

- `board/lisa/lisa.dtb` — stock device tree (Mu-Silicium, extracted from a lisa
  boot image). Addresses quoted below are from this tree.
- LineageOS `android_device_xiaomi_lisa` and `android_kernel_xiaomi_sm8350`
  (`arch/arm64/boot/dts/vendor/qcom/lisa-sm7325.dtsi`, `yupik*.dtsi`,
  `display/dsi-panel-k9d-*.dtsi`).
- Project-Silicium `Mu-Silicium` `Platforms/Xiaomi/lisaPkg` (UEFI memory map,
  which independently lists the same display/UFS/IMEM windows).

Verify the DTB against the actual phone before trusting any of it
(`tools/lisa-device-dump.sh`).

## SoC and CPUs

| | lisa | sweet (reference) |
|---|---|---|
| SoC | SM7325, Snapdragon 778G | SM7150, Snapdragon 730G/732G |
| Cores | 4x Cortex-A78 (1x 2.4 GHz + 3x 2.2 GHz) + 4x Cortex-A55 | 2x Cortex-A76 + 6x Cortex-A55 |
| MPIDR (Aff1:Aff0) | A55 = 0x000..0x300, A78 = 0x400..0x700 | 0x000..0x500 A55, 0x600..0x700 A76 |
| ISA | ARMv8.2-A, crypto, **no** pointer auth in our build | ARMv8.2-A, crypto |
| GIC | GICv3, GICD `0x17a00000`, GICR `0x17a60000` + 1 MiB | same |
| Timer | 19.2 MHz (`0x124f800`); EL1 virtual timer INTID **27** | 19.2 MHz; virtual timer INTID **19** |
| PSCI | `arm,psci-1.0`, `smc` | same |

`cpus=N` in the boot-args starts a prefix in DT order, so `cpus=4` starts only
the A55 cluster (the conservative bring-up choice); `cpus=8` includes the A78s.

## Memory

DT memory node (8 GiB sample):

```
<0x80000000 0x39700000>   low bank, 0x80000000..0xb9700000
<0xc0000000 0xc0000000>   3 GiB at 3 GiB
<0x180000000 0x100000000> 4 GiB at 6 GiB
```

All fixed reserved-memory regions (hyp, SMEM, modem, ADSP, CDSP, WLAN, PIL,
splash, …) and every dynamic pool (`alloc-ranges` capped at `0xffffffff`) live
below 4 GiB. The port therefore takes the **4–6 GiB window** for XNU:

```
PHYS_BASE = 0x100000000
MEM_SIZE  = 0x08000000   (2 GiB)
```

This window is present on both the 6 GiB and 8 GiB variants. `0x180000000` and
above is only used once the phone's own `/proc/iomem` confirms the top of DRAM
for that exact variant (see the TODO in `docs/porting-plan.md`).

## Display

- Panel: 6.67" AMOLED, **1080x2400**, 60/90 Hz, DSC **command mode**.
- Panel drivers: `dsi-panel-k9d-36-02-0a-dsc-cmd` (BOE, 0x36) and
  `dsi-panel-k9d-42-0d-0b-dsc-cmd` (CSOT, 0x42); selected by `msm_drm.dsi_display0`.
- ABL leaves a continuous-splash framebuffer at **`0xe1000000`, size
  `0x2300000`** (`cont_splash_region`; UEFI calls it "Display Reserved").
  This is the lisa equivalent of sweet's `0x9c000000` and is what the shim's
  console and the kernel's IOSurface copy target.
- MDP/DSI block: `qcom,mdss_mdp@ae00000` (DSI PHY etc. are in the same tree).
  We do **not** drive DSI in the first milestones; frames are copied into the
  bootloader framebuffer, exactly like ios-sweet.

## Storage

- UFS host: `ufshc@1d84000`, reg `0x1d84000` (ufs_mem, `0x3000`), `0x1d88000`
  (ICE), `0x1d90000` (ICE HWKM). Same IP and base address as sweet.
- UFS-PHY `qcom,ufs-phy-qmp-v4-yupik`, 2 lanes, UFS 2.2/3.1 depending on SKU.
- Root strategy is unchanged: an HFS+ iOS root image in the existing `userdata`
  partition (`rd=ufsroot0 ufsrw=1 rootrw=1`). No GPT changes.

## Touch, keys, PMIC

- Touch: **Goodix GT9897T** (firmware `goodix_gt9897t_*_k9d*.bin`) on
  **QUPv3 SE13 SPI**, `spi@a94000` (SPI, not I²C — this differs from sweet's
  GT9896 on I²C). IRQ GPIO 81, reset GPIO 105, `avdd` = PM7325 L7C,
  `iovdd` = L2C, max 1080x2400, 10-point.
- Power/volume-down: PMK8350 PON (`spmi` SID 0). Volume-up: PM7325 GPIO 6
  (SID 1, active low).
- PMICs: PM7325, PM7325B, PMK8350, PMR735A (SPMI arb at `0xc440000`).
- Haptics: AW8624 on QUPv3 SE4 I²C (`0x5a`), reset GPIO 35, IRQ GPIO 18.
- Fingerprint: FPC side-mounted, SPI/GPIO (not needed for the port).
- Battery/charger: PM7325 family (the sweet IOPMPowerSource driver needs a new
  fuel-gauge path; a static battery is acceptable for bring-up).

## Boot chain

```
ABL (unlocked bootloader)
  -> fastboot boot shim-boot.img        (boot image v4; nothing flashed)
     -> shim: reads the live FDT (embedded copy as fallback), loads the
        payload appended after _end in our own Image (v4 drops the boot
        ramdisk), and jumps to XNU
        -> XNU + generated ADT + boot-args
           -> UFS driver -> HFS+ root in userdata
              -> launchd -> backboardd + SpringBoard
```

v4 is required by this Xiaomi ABL for `fastboot boot`; v1/v2/v3 are rejected
even for the stock boot image. The same firmware also passes only the
vendor_boot ramdisk, hence the payload-in-Image layout (the `ios-topaz` port
documented this on SM6225). `tools/mkbootimg.py` output is byte-identical to
AOSP `mkbootimg.py` for the same v4 arguments.

The shim's diagnostic boot (no payload) prints CPU feature registers,
PSCI/SMCCC results, GIC/timer interrupts and a UFS register dump to the
framebuffer. It is confirmed on lisa: the ABL splash framebuffer is
`0xe1000000` (size `0x2300000`) and scan-out is live. Reset re-enters the
active slot, so with slot A active a test returns to Android.

## USB

- DWC3 at `0xa600000` (`androidboot.usbcontroller=a600000.dwc3`). The first
  milestones do not need USB from the shim or XNU; recovery/adb is used for
  logs instead.

## Open questions (answer from the actual phone)

Answered by the shim run on 2026-10-20:

1. DRAM: 8 GiB total on this unit; the live FDT banks are `0x80000000`
   (`0x39700000`), `0xc0000000` (`0xc0000000`) and `0x180000000`
   (`0x100000000`). `0x100000000..0x1ffffffff` is contiguous RAM and free of
   reserved-memory carve-outs (highest carve-out ends at `0xe3400000`).
2. The splash framebuffer survives at `0xe1000000`, size `0x2300000`,
   1080×2400, and the shim's writes are visible.

Still open:

3. Which panel variant (BOE 0x36 / CSOT 0x42) and whether a simple framebuffer
   copy is enough for the first SpringBoard frame.
4. GT9897T SPI protocol details (the downstream `goodix_core` driver is the
   reference; it is a different transport from sweet's I²C GT9896).
5. PM7325 regulator votes needed for the touch rails (L7C/L2C) and the AMOLED
   `disp_cc`/`vreg` rails.
