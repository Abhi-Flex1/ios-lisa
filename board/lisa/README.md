# lisa board files

`lisa.dtb` is the stock device tree used by the bootloader for the Xiaomi 11
Lite 5G NE (`lisa`, SM7325). The shim needs it in the `fastboot boot` image so
ABL configures the board (clocks, regulators, UFS, display) the same way it
does for Android.

Provenance: copied 2026-10-20 from
[Project-Silicium/Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium)
`Resources/DTBs/lisa.dtb`, which that project extracted from a lisa boot image.
It is a vendor artifact and is not covered by this repository's Apache-2.0
license.

**Verify it against the actual phone before trusting it.** A `boot.img` pulled
from the phone with `tools/lisa-device-dump.sh` contains the authoritative DTB:

```
python3 tools/unpack_bootv2.py backup/boot.img dtb/lisa
cmp dtb/lisa/dtb board/lisa/lisa.dtb
```

If they differ (different RAM size or hardware revision), use the dumped file
for the build:

```
DTB=dtb/lisa/dtb shim/build.sh
```

The DTB is also the source of every address in `shim/board.h` and
`tools/mkadt.py`. Re-check those if the phone's tree differs.
