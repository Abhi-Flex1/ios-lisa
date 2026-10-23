# HackiOS as the lisa bring-up base

Decision (2026-10-23): the iOS 16 userland on lisa is built on
[HackiOS](https://github.com/oosexgang/hackios-xnu-kernel) instead of the
prelink/IOStorageFamily/SHNGROOT line.  HackiOS targets the POCO X5 Pro 5G
(`redwood`, **SM7325 — the same SoC as lisa**) and brings:

- XNU 8796.121.2 built from public source (no kernelcache prelink);
- its own APFS and ramfs VFS (`bsd/miscfs/apfs`, read/write) — no
  IOStorageFamily, no `vfs_getvfs_with_vfsops`;
- its own SM7325 UFS driver (`redwood_ufs.c`, `redwood_ufshc.c`, controller
  at **`0x1d84000`**, identical to ours);
- a Mu-Silicium UEFI + EFI loader boot chain started with `fastboot boot`;
  the system image is uploaded over USB into RAM (`xl ramdisk`), so nothing
  is flashed;
- generic arm64 platform code (GICv3, timer, PSCI SMP, UEFI framebuffer),
  Goodix touch, WCN6750 Wi-Fi, Adreno 642L — lisa has the same blocks
  (touch is a Goodix **GT9897T** instead of GT9916).

Mu-Silicium already carries `Platforms/Xiaomi/lisaPkg`,
`Resources/DTBs/lisa.dtb` and `Configs/lisa.toml`, and its UEFI FD base/size
(`0x9FD00000` / `0x200000`) equal redwood's `FD_BASE`/`FD_SIZE`, so the boot
shim addresses carry over unchanged.

## Layout

| Path | What |
|---|---|
| `pins.env` | upstream repositories and the exact commits we build |
| `ci-fetch.sh` | clone one upstream repository at its pinned commit (no history) |
| `patches/` | our lisa patch series on top of the pinned HackiOS tree |
| `../.github/workflows/hackios.yml` | CI: theos + SDK, kernel, loader, artifacts |

The vendor trees are **not** committed: CI clones them at the pinned SHA and
applies `patches/*.patch`.

## Build

Everything runs in GitHub Actions (`ubuntu-24.04`):

```
gh workflow run hackios.yml        # or: push to hackios/
```

The job installs theos with its Linux cctools
(`L1ghtmann/llvm-project` `iOSToolchain-x86_64`) and `iPhoneOS16.5.sdk`,
then runs, exactly as upstream documents:

```
xnu/apply.sh
xnu-deps/setup.sh
./xnu-build.sh -j"$(nproc)" -k
```

`-k` and a failing exit status are expected: XNU's `check_all_exports` runs
after the kernel is linked.  Judge by the file
`xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837`.

Artifacts: the kernel, the EFI loader, the build log, and a `SHA256SUMS`.

## Milestones

1. **Stock redwood kernel builds in CI** — proves the toolchain, no patches.
2. **lisa UEFI** — Mu-Silicium `lisaPkg` + HackiOS's `mu-silicium.patch`,
   booted with `fastboot boot`; the loader must answer `xl state`.
3. **lisa platform** — `common/devices/lisa.conf` + `platform_lisa` in
   `xnuloader/loader.c` (UFS/APFS are SoC-generic), boot `touchscreen=0`.
4. **GT9897T touch** — port `redwood_goodix.c` to the k9d panel.
5. **System image** — iOS 16.5 APFS images (`ios165/fetch.sh` needs the IPSW
   on a machine with ~12 GB free; can run in CI as an artifact step later).
