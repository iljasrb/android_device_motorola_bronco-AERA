# AERA Recovery — Motorola ThinkPhone (bronco)

Device tree for [AERA Recovery](https://github.com/AERA-Recovery) `aera-16.0`
(Android 16) on the Motorola ThinkPhone (`bronco`, SM8475 / taro).

- Device: `bronco` (`bronco_g` in Android), codename `aera_bronco`
- Recovery: TWRP-based AERA UI, ramdisk-only image (header v4, 100 MiB, `kernel_size=0`)
- Maintainer: [@iljasrb](https://github.com/iljasrb)
- Downloads: <https://rom.flac.moe/bronco/recovery/AERA/latest/>

## Features

| | |
|---|---|
| Decryption | Metadata (FBE-DE) on boot, CE/user 0 via PIN or password |
| Storage | `/data`, internal storage, `/persist` bind mount, backup/restore, file manager |
| Install | Zip from internal storage or ADB sideload, ROM OTAs with dynamic partitions (virtual A/B) |
| Connectivity | adb, MTP (FunctionFS), Wi-Fi (QCA6490) with zip installs while connected |
| fastbootd | `getvar`, physical + logical partitions, `fetch`, live and cold entry |
| Extras | Root manager (KernelSU family), terminal, plugin store, flashlight, haptics |

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

Output: `$AERA_DIR/out/target/product/bronco/AERA-R1.0-Beta-Official-bronco.img`
(installer zip alongside it).

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

## Layout

```
AndroidProducts.mk BoardConfig.mk device.mk aera_bronco.mk twrp_bronco.mk
recovery.fstab system.prop vendorsetup.sh Android.mk Android.bp
recovery/root/            ramdisk overlay (init rc, crypto, WLAN, spss, fastbootd)
patches/                  local changes applied to AOSP/AERA repositories
scripts/publish.sh        upload a build to the mirror
```

## Credits

AERA Recovery, TWRP, and the LineageOS bronco/sm8475 trees this port started from.
