# AERA Recovery — Motorola ThinkPhone (bronco)

Device tree for [AERA Recovery](https://github.com/AERA-Recovery) `aera-16.0`
(Android 16) on the Motorola ThinkPhone (`bronco`, SM8475 / taro).

- Device: `bronco` (`bronco_g` in Android), codename `aera_bronco`
- Recovery: TWRP-based AERA UI, ramdisk-only image (header v4, 100 MiB, `kernel_size=0`)
- Maintainer: [@iljasrb](https://github.com/iljasrb)
- Downloads: <https://rom.flac.moe/bronco/recovery/aera/latest/>
- Update feed: <https://rom.flac.moe/bronco/recovery/aera/catalog.json> (in-recovery updater)

## Features

| | |
|---|---|
| Decryption | Metadata (FBE-DE) on boot, CE/user 0 via PIN or password |
| Storage | `/data`, internal storage, `/persist` bind mount, backup/restore, file manager |
| Install | Zip from internal storage or ADB sideload, ROM OTAs with dynamic partitions (virtual A/B) |
| Connectivity | adb, MTP (FunctionFS), Wi-Fi (QCA6490) with zip installs while connected |
| fastbootd | `getvar`, physical + logical partitions, `fetch`, live and cold entry |
| Security | Screen-lock PIN/password, FRP wipe |
| Extras | Root manager (KernelSU family), terminal, plugin store, flashlight, haptics |
| Rendering | Adreno 730 via KGSL + EGL/GLES, software LVGL fallback |
| Audio | Silent fallback; no DSP soundcard in recovery yet |

GPU rendering ships the Adreno userspace in the ramdisk: `libEGL_adreno.so`,
`libGLESv2_adreno.so`, `libgsl.so`, `libadreno_utils.so`, `libllvm-glnext.so`,
the `eglSubDriverAndroid.so` platform subdriver with the graphics
mapper/allocator interface libraries it links against, kgsl's GMU firmware
(`vendor/firmware/gmu_gen70000.bin`), the Adreno 730 SQE/ZAP firmware
(`a730_sqe.fw`, `a730_zap.*`) and the platform `libui`/`libnativewindow` built
into the ramdisk by `device.mk`. The SQE/ZAP firmware is staged under
`/system/etc/firmware` (visible as `/etc/firmware`) because KGSL requests it
during first-stage init, before `spss-start.sh` mounts `/firmware`, and a later
`/vendor` mount would hide a copy under `/vendor/firmware`. The renderer composites into a pbuffer
and copies the frame into minui's DRM scanout buffer, so no gralloc allocation,
mapper service or allocator service is involved. The vendor libraries are the
proprietary blobs from the installed Motorola Android 17 vendor partition;
refresh them from a vendor dump after a ROM update.

## Requirements

- Synced `aera_16.0` checkout (`repo sync` of the AERA manifest)
- Linux host with the AOSP build dependencies, `zip`

## Build

```sh
AERA_DIR=~/aera_16.0 ./build.sh
```

`build.sh` installs this tree to `$AERA_DIR/device/motorola/bronco`, applies the
patches from `patches/` to the AOSP repositories, and runs
`lunch twrp_bronco-bp2a-eng && mka adbd recoveryimage`.

Useful options: `--patches-only` installs the tree and applies patches without
building, `--clean` removes the AERA `out/` tree first, `--ccache` enables
ccache when installed, `--jobs N` overrides the build parallelism, and `--sync`
runs `repo sync` first when the `repo` tool is available. The device tree is
installed with `rsync` when present, so unchanged files keep their timestamps
and incremental builds only rebuild what changed.

Output: `$AERA_DIR/out/target/product/bronco/AERA-R1.0-Beta-Unofficial-bronco.img`
(installer zip alongside it). The status segment follows `AERA_BUILD_STATUS`
from `vendorsetup.sh`; `Official` only appears when that is set explicitly.

## Flash

```sh
adb reboot bootloader
fastboot flash recovery_a AERA-R1.0-Beta-Official-bronco.img
fastboot flash recovery_b AERA-R1.0-Beta-Official-bronco.img
fastboot reboot recovery
```

Flash both slots: an A/B OTA switches slots, so a single-slot recovery is lost
on the next update. The installer zip (`out/AERA-bronco-#NN-*.zip`) flashes both
slots from inside recovery and reboots.

## Notes and limits

- Recovery decrypts metadata encryption on the first boot pass; a second decrypt
  after a in-recovery restart is not guaranteed.
- Format Data wipes the partition and lets the ROM create the filesystem on the
  next boot: the metadata `dm-default-key` mapping cannot be dropped while the
  kernel holds it, so `mkfs.f2fs` cannot take the partition (`In use by the
  system!`). A bootloader-level `fastboot erase userdata` does the same.
- `fastboot -w` and `getvar partition-size:userdata` are unavailable for the same
  reason.
- ROM installs are staged as virtual-A/B snapshots. Wipe `userdata`/`metadata`
  before installing, never after — erasing `/metadata` destroys the staged slot.
- Wi-Fi runs from RAM; `/vendor` is released after boot so zips that mount it work.
- Audio output is not implemented: the browser/media plugins use the silent
  fallback. The DSP audio protection domain does not start and the recovery DTB
  lacks the sound machine/codec nodes; see `TODO.md`.
- The FRP wipe row is compiled in (`AERA_ENABLE_FRP_WIPE := 1`) but unselected
  by default. It writes the raw `frp` block device and fails closed if the
  bootloader protects it.

## Ramdisk scripts

The behaviour that matters most on this device lives in `recovery/root/system/bin`,
not in `patches/`. Each hook exists because of a specific failure; keep that link
when changing one.

| script | trigger | what it does / failure it prevents |
|---|---|---|
| `crypto-start.sh` | init, before the crypto chain | Runs `aera-format-pending.sh take` first, then starts gatekeeperd/keystore2 in the order KeyMint needs. Ordering here is what makes password decryption work. |
| `aera-format-pending.sh` | `mark` from the UI, `take` from `crypto-start.sh` | `mark` leaves `/metadata/aera-format-pending` and restarts recovery; `take` formats raw userdata before `dm-default-key` exists, zeroes `/metadata`, and mounts once with checkpoints enabled. Needed because `mkfs.f2fs` cannot take a mapped partition. |
| `wlan-start.sh` | `crypto-start.sh`, after `/data` is ready | Mounts vendor/vendor_dlkm privately, stages config + `wlan_mac.bin` on tmpfs, loads `qca_cld3`, releases those mounts, then brings `wlan0` up. Sockets live on a tmpfs over `/data/vendor/wifi` — writing them into real `/data` left unlabeled files that stop Android's `cnss-daemon` and killed Wi-Fi until a data wipe. |
| `release-mounts.sh` | `setprop aera.release.mounts 1` | Lazily detaches `/vendor` and `/vendor_dlkm` so TWRP can unmap super for installs and fastbootd. Must not stop the Wi-Fi stack. |
| `spss-start.sh` | init, early | Brings up spss/spdaemon and bind-mounts `/mnt/vendor/persist` to `/persist`; never unmounts the NVM partition under its owners. |
| `ssgtzd-start.sh` | init, early | Starts the storage security daemon; it pins `/vendor`, which is why the release hook exists. |
| `prepdecrypt.sh`, `mtp-fallback.sh` | init / USB events | Pre-decrypt prep and MTP fallback to the legacy USB function. |

## Layout

```
AndroidProducts.mk BoardConfig.mk device.mk aera_bronco.mk twrp_bronco.mk
recovery.fstab system.prop vendorsetup.sh Android.mk Android.bp
recovery/root/            ramdisk overlay (init rc, crypto, WLAN, spss, fastbootd)
patches/                  local changes applied to AOSP/AERA repositories
scripts/publish.sh        upload a build and refresh the update catalog
```

## Credits

AERA Recovery, TWRP, and the LineageOS bronco/sm8475 trees this port started from.
