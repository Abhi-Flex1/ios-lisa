# Building the iOS 16 root image (Linux host)

The iOS userland is Apple's copyrighted content. It never goes into git; the
`research/` directory is ignored. The root is the **iPhone X (D22AP) iOS
16.7.16 20H392** system, the same userland the upstream `ios-sweet` port runs.
The lisa-specific identity (board, CPU, display, UFS) comes from the generated
ADT, so the root image itself is not lisa-specific yet.

## Inputs

- IPSW: `iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw`
  - URL (ipsw.me, 2026-10-20):
    `https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw`
  - size 6,171,035,648 bytes,
    sha256 `ece1194f7e233e9109c5790a8d23a4564a10a254e15ec5b09978a343265568fb`.
- The three DMGs inside it (sizes from the ZIP central directory):
  - `087-86698-044.dmg` 4,730,814,044 B — the OS root (`OS.dmg`)
  - `087-86593-047.dmg` 2,743,074,816 B — the SystemOS cryptex
  - `087-86715-047.dmg` 10,485,760 B — the AppOS cryptex
- Linux host with `apfs-fuse`, `hfsprogs` (`mkfs.hfsplus`, `fsck.hfsplus`),
  `rsync`, `img2simg`, and passwordless `sudo` (the script copies as root and
  loop-mounts the HFS+ image).
  - Arch: `sudo pacman -S apfs-fuse hfsprogs rsync android-tools`
  - Debian/Ubuntu: `sudo apt install apfs-fuse hfsprogs rsync android-sdk-libsparse-utils`

## 1. Get only the three DMGs (no 6 GB full unzip)

`tools/remotezip.py` reads the ZIP central directory and fetches members with
HTTP range requests, so the 6 GB IPSW never has to be stored whole:

```
python3 tools/remotezip.py "$IPSW" 087-86698-044.dmg /tmp/ios-dmgs
python3 tools/remotezip.py "$IPSW" 087-86593-047.dmg /tmp/ios-dmgs
python3 tools/remotezip.py "$IPSW" 087-86715-047.dmg /tmp/ios-dmgs
```

The member names are at the ZIP root (not under `Firmware/`); the matching
`.root_hash`/`.trustcache` files are not needed by `mkiosroot.sh`.

## 2. Get the D22AP DeviceTree (for the ADT `/product` node)

Only 33 KiB; `mkadt.py` wants it as a raw ADT at
`research/ipsw-x/d22ap.adt`:

```
python3 tools/remotezip.py "$IPSW" DeviceTree.d22ap /tmp/d22ap
python3 tools/adt.py unwrap \
    /tmp/d22ap/Firmware/all_flash/DeviceTree.d22ap.im4p \
    research/ipsw-x/d22ap.adt
```

Requires `lzfse` (`brew install lzfse` on macOS, `lzfse`/`liblzfse` on Linux).
Without the file `mkadt.py` warns and omits `/product`; the kernel still boots
but MobileGestalt gets no product identity.

## 3. Build the HFS+ image (root)

```
sudo tools/mkiosroot.sh \
    /tmp/ios-dmgs/087-86698-044.dmg \
    /tmp/ios-dmgs/087-86593-047.dmg \
    /tmp/ios-dmgs/087-86715-047.dmg \
    ios16-root-20H392-lisa.img 16G
```

What the script does (see its header for the full rationale):

- one **case-sensitive journaled HFS+** volume (XNU replays the journal);
- copies the OS root, then the SystemOS/AppOS cryptexes under
  `/private/preboot/Cryptexes/{OS,App}`;
- hard-links the dyld shared cache to `/System/Library/Caches/com.apple.dyld`
  and the cryptex files that dyld does not search at `ignition_level=1`;
- creates the `logd` store dirs with uid/gid 272 and `.migrated`, and a plain
  plist `systembag.kb` for the built-in `AppleKeyStore`;
- `fsck.hfsplus -f -n` at the end.

Then make the sparse image fastboot will accept:

```
img2simg ios16-root-20H392-lisa.img ios16-root-20H392-lisa.simg
sha256sum ios16-root-20H392-lisa.img > ios16-root-20H392-lisa.img.sha256
```

Do not commit the `.img`/`.simg`; they are iOS userland.

## 4. Flash and boot (destructive — confirm first)

The root lives in `userdata`, so this **erases Android's user data**. It is a
separate destructive step; get explicit confirmation immediately before the
command, and keep the Android boot image on slot A.

```
fastboot flash -S 512M userdata ios16-root-20H392-lisa.simg   # ~25 chunks
```

After a large flash the Xiaomi ABL sometimes hangs; re-enter fastboot with
Power + Vol-Down, do not unplug mid-flash.

The root boot command line (upstream sweet):

```
debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress \
rd=ufsroot0 ufsrw=1 rootrw=1 ignition_level=1 launchd_unsecure_cache=1 \
wdt=-1
```

Build the payload with that line, then the v4 boot image:

```
python3 tools/mkpayload.py xnu/out-<run>/kernel.development.sweet \
    shim/out/lisa-hi.adt shim/out/payload-root.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1 ignition_level=1 launchd_unsecure_cache=1 wdt=-1'
BOARD=lisa shim/build.sh "$PWD/shim/out/payload-root.bin"
```

The first root boot should be observed before adding touch/display work; the
framebuffer console and the kernel panic screen are the only diagnostics on
lisa (no UART).
