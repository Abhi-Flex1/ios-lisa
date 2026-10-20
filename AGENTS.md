# Working on ios-lisa

Porting the ios-sweet XNU/iOS-16 bring-up from `sweet` (SM7150) to `lisa`
(Xiaomi 11 Lite 5G NE, SM7325). Read these first, in order:

1. `docs/porting-plan.md` — milestones and the next concrete action.
2. `docs/lisa-hardware.md` — every address and its source.
3. `NOTES.md` — live handoff: what actually happened on the phone/CI.

`docs/upstream-sweet-NOTES.md` is the upstream ios-sweet engineering log. It is
the best explanation of *why* the kernel patches look the way they do, but it
describes a different board; do not treat its addresses as lisa facts.

## Safety rules (non-negotiable)

- Bring-up images are loaded with `fastboot boot` only. Never flash `boot`,
  `dtbo`, `vbmeta`, `super`, bootloader or any partition without the user's
  explicit confirmation for that specific command.
- The user has **not** approved erasing Android. The iOS root eventually
  overwrites `userdata`; treat that as a separate destructive step and confirm
  immediately before it.
- `persist`, `modemst1`, `modemst2`, `fsg`, `fsc` contain the IMEI and RF
  calibration. Back them up before any experiment and never write to them.
- Keep `backup/`, `dtb/`, `dbg/`, IPSWs, root images and serial numbers out of
  git (`.gitignore` covers the directories).
- Security is disabled by design (permissive AMFI, stub keystore). Do not put
  personal data on the device.

## Conventions

- Board constants live in exactly two places: `shim/board.h` and the `BOARDS`
  table in `tools/mkadt.py`. Change both together.
- `mkadt.py` and `shim/build.sh` default to `lisa`; `BOARD=sweet` / `--board
  sweet` keeps the upstream baseline available for diffing.
- The XNU patch series and the `SWEET` machine config keep their upstream
  names. Renaming is cosmetic and would churn 69 patches; the ADT still carries
  `xiaomi,sweet` as a compatibility string for the platform expert.
- New board-specific behaviour goes behind `BOARD_LISA` in C, or a row in
  `BOARDS` in Python. Avoid scattering new hardcoded addresses.
- Every claim in `docs/` needs a source: the phone's own output, the stock DTB,
  or a named downstream tree. Mark guesses as guesses.

## Commands

```
tools/lisa-device-dump.sh                  # read-only inventory; needs adb
BOARD=lisa shim/build.sh                   # diagnostic shim (needs cross gcc)
BOARD=lisa shim/build.sh shim/out/payload.bin
python3 tools/mkadt.py shim/out/lisa.adt --board lisa --highmem
python3 tools/mkpayload.py KERNEL shim/out/lisa.adt shim/out/payload.bin \
    --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1'
fastboot boot shim/out/shim-boot.img
```

Kernel builds run in GitHub Actions (the Mac has CLT, not Xcode):
`gh workflow run xnu.yml -R OWNER/ios-lisa`, then download the `xnu-kernel`
artifact. Record the run ID.

## Handoff discipline

Update `NOTES.md` after every milestone and before stopping: exact commands,
build/run IDs, what appeared on screen, what the log said, and the single next
action. Distinguish observations from guesses. Commit completed changes.
