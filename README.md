# ios-lisa

An experimental port of Apple's **real iOS 16.5 userland and XNU** to the
Xiaomi 11 Lite 5G NE (`lisa`, Qualcomm SM7325 / Snapdragon 778G). The current
bring-up is based on pinned [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel)
and [Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) sources. It
is not affiliated with Apple or Xiaomi, and is not an iOS theme, launcher, or
virtual machine.

This is a research project, **not a consumer-ready installation**. Treat every
hardware result below as a dated experiment, not a promise that the device is
currently running iOS or that every iPhone feature works.

## Status on the physical phone

The latest successful iOS-on-device run recorded in [`NOTES.md`](NOTES.md) is
from **2026-10-23**. The latest device-state entry, dated **2026-10-24**, says
Android was restored and the earlier iOS image in `userdata` was erased. No
later iOS run is recorded; repeating the test requires rebuilding or reloading
the images.

What has been demonstrated on this lisa:

- The UEFI/loader path starts with `fastboot boot` (the tested HackiOS flow
  does not flash a boot or system partition). XNU then booted into the iOS
  16.5 userland, started `launchd.ios` and SpringBoard, and displayed the home
  screen on the phone.
- The kernel was separately tested with all eight CPU cores and the reported
  CPU-frequency groups. The first recorded SpringBoard run used one CPU; do
  not infer that every configuration was tested together.
- The Goodix GT9897T was identified and initialized, and real touch reports
  reached the input path. The initial report coordinates were scaled
  incorrectly; a coordinate-range correction was prepared but the notes do not
  record a confirming hardware run. Consider usable touch **incomplete**.
- The Adreno 642L hardware, firmware, and command path were brought up. The
  recorded UI run still used software rendering; end-to-end Mesa/OpenGL
  acceleration has not been demonstrated.

Wi-Fi, Bluetooth, cellular, audio, camera, GPS, and other device features are
not established as working by the recorded tests. See the dated log for the
observations, commands, and limitations behind these summaries.

## How this repository is used

This repository tracks the lisa-specific patches, pinned source revisions,
image-building helpers, and CI workflows; the upstream kernel and userland
checkouts and Apple's iOS image are fetched separately and are not committed.
The system image is loaded into memory by the loader over USB in the documented
HackiOS run flow.

- [`hackios/pins.env`](hackios/pins.env) pins the upstream kernel and userland
  revisions and related build inputs.
- [`hackios/patches/`](hackios/patches/) contains the UEFI changes;
  [`hackios/patches-kernel/`](hackios/patches-kernel/) and
  [`hackios/patches-userland/`](hackios/patches-userland/) contain lisa-specific
  kernel and userland changes.
- [`hackios/device/lisa.conf`](hackios/device/lisa.conf) records the device
  profile used by the build.
- [`hackios/system-image.sh`](hackios/system-image.sh) prepares the upstream
  checkout and builds the iOS 16.5 APFS images. It downloads about 7.4 GB from
  Apple's CDN and needs roughly 8 GB of free space while fetching, plus room
  for the resulting images. Apple's copyrighted image contents are not stored
  in this repository.
- [`hackios/boot-test.sh`](hackios/boot-test.sh) uses `fastboot boot` to start
  a prepared boot image and check that the loader answers over USB. It does not
  flash a partition.
- [`.github/workflows/hackios.yml`](.github/workflows/hackios.yml) builds the
  pinned kernel and loader; [`.github/workflows/hackios-uefi.yml`](.github/workflows/hackios-uefi.yml)
  builds the lisa UEFI image; [`.github/workflows/hackios-gl.yml`](.github/workflows/hackios-gl.yml)
  builds the OpenGL/Mesa components.

For implementation details, see [`hackios/README.md`](hackios/README.md).
Some milestone text there and in [`docs/`](docs/) predates the successful
hardware runs; use the newest entries at the top of [`NOTES.md`](NOTES.md) for
the latest recorded results. The old `shim/` and `xnu/patches/` bring-up path
remains in the tree for reference; the active strategy is the HackiOS-based
flow.

## Device and data safety

- Use `fastboot boot` for bring-up images. Do not flash boot, DTB, or other
  partitions as part of routine testing.
- The historical root-image experiment used `userdata`, which erases Android
  user data. That image was erased when Android was restored. Any future write
  to `userdata` is a separate destructive operation and must be explicitly
  approved before it is performed.
- Do not write to `persist`, `modemst1`, `modemst2`, `fsg`, or `fsc`; they hold
  device identity and radio calibration data.
- Do not commit phone backups, device dumps, IPSWs, firmware blobs, or extracted
  Apple system images. Do not use personal data on experimental builds.

## Hardware reference

The target is the **Xiaomi 11 Lite 5G NE** (`lisa`, SM7325), not the similarly
named `renoir` or `Mi 11 Lite 5G`. Lisa shares major SoC blocks with the POCO X5
Pro (`redwood`), the HackiOS reference target, but board differences still
matter. [`docs/lisa-hardware.md`](docs/lisa-hardware.md) records address sources
and known differences; verify device-tree assumptions against the actual
phone before relying on them.

## Credits and licensing

This work builds on [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel),
[Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium), Apple's
open-source XNU and iOS components, and the lisa device and kernel sources.
The repository is licensed under Apache-2.0 (see [`LICENSE`](LICENSE)). The
stock lisa device tree under [`board/lisa/`](board/lisa/) is a vendor artifact
and is not covered by that license; see its [provenance note](board/lisa/README.md).
Apple's iOS userland and IPSW contents are copyrighted and are not distributed
here.
