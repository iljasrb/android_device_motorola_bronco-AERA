#!/usr/bin/env bash
# Build AERA recovery for bronco.
#
#   AERA_DIR=~/aera_16.0 ./build.sh
#
# Installs this tree into $AERA_DIR/device/motorola/bronco, applies the patches
# in patches/, and builds recoveryimage.
set -eo pipefail
# not -u: AOSP's envsetup.sh/lunch reference unbound variables (TOP).

readonly root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly aera_dir="${AERA_DIR:?set AERA_DIR to a synced aera_16.0 checkout}"
readonly dest_tree="$aera_dir/device/motorola/bronco"

tree_files=(
    Android.bp
    Android.mk
    AndroidProducts.mk
    BoardConfig.mk
    device.mk
    aera_bronco.mk
    twrp_bronco.mk
    recovery.fstab
    system.prop
    vendorsetup.sh
    recovery
)

[[ -f "$aera_dir/build/envsetup.sh" ]] || {
    printf 'AERA_DIR (%s) is not a synced aera_16.0 checkout\n' "$aera_dir" >&2
    exit 1
}

rm -rf "$dest_tree"
mkdir -p "$dest_tree"
cp -a "${tree_files[@]/#/$root_dir/}" "$dest_tree"/
printf 'Installed device tree at %s\n' "$dest_tree"

# AERA's plugin store, updater and font downloader call `busybox wget`; the AERA
# ramdisk script drops /sbin/busybox, so install the vendored static busybox at
# the documented fallback path.
install -D -m 0755 "$aera_dir/vendor/recovery/prebuilt/arm64/busybox" \
    "$dest_tree/recovery/root/system/bin/busybox"

# A16 keystore2 sends the operation NONCE to KeyMint upgradeKey(); the vendor TA
# rejects it with INVALID_ARGUMENT and A17-encrypted /data does not mount.
ks2="$aera_dir/system/security/keystore2"
grep -q 'filtered_params' "$ks2/src/utils.rs" ||
    git -C "$ks2" apply "$root_dir/patches/keystore2-strip-nonce-from-upgrade.patch"

# Recovery resolves HIDL to passthrough; ENFORCE_VINTF_MANIFEST rejects the
# gatekeeper registration and the vendor HAL is unreachable.
hidl="$aera_dir/system/libhidl"
grep -q 'libhidl still resolves' "$hidl/Android.bp" ||
    git -C "$hidl" apply "$root_dir/patches/libhidl-disable-enforce-vintf.patch"

# fastbootd resolves health/fastboot HALs while USB is still closed; recovery has
# neither, so the blocking waits hang the daemon and USB never re-enumerates.
core="$aera_dir/system/core"
grep -q 'Never wait here: fastbootd is' "$core/fastboot/device/fastboot_device.cpp" ||
    git -C "$core" apply "$root_dir/patches/fastbootd-hal-nonblocking.patch"

recovery_mod="$aera_dir/bootable/recovery"

# Prefer the bootloader's factory wifimacaddr= over the serial-derived MAC.
grep -q 'wifimacaddr=' "$recovery_mod/wlan.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-wlan-factory-mac.patch"

# TestConnection used `busybox ping`, absent here; probe with native sockets.
grep -q 'static bool ProbeTcp' "$recovery_mod/wlan.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-wlan-native-connectivity-test.patch"

# The Wi-Fi switch consumed the tap, so only the label toggled the radio.
grep -q 'The switch is only an indicator' "$recovery_mod/aeraui/scenes/wifi_scene.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/aeraui-wifi-toggle-click.patch"

# The animated fastboot hand-off segfaulted inside LVGL before
# RecoveryEnterFastbootd(); use a fade, fall back to cold boot-fastboot, and use
# the sys.usb.config.aera_fastbootd marker (ro.* writes are dropped).
grep -q 'crashed inside LVGL before RecoveryEnterFastbootd' \
        "$recovery_mod/aeraui/components/power_transition.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/aeraui-fastbootd-live-entry.patch"

# Sideload serves the package over FUSE, which has no random access; the zip
# installer aborted mid-package. Stage it in tmpfs first.
grep -q 'kLocalPackage' "$recovery_mod/twrpinstall/adb_install.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-sideload-stage-package.patch"

# Recovery pins /vendor for the boot once its libraries are mapped; the zip
# installer refuses to run until /vendor is unmounted. Release it before install.
grep -q 'ReleaseVendorMountsForInstall' "$recovery_mod/aeraui/platform/aera_backend.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-release-vendor-before-install.patch"

# make_f2fs leaves userdata checkpoint-disabled, so every write made in a
# recovery session was rolled back on the next boot (settings, backups).
grep -q 'checkpoint=enable' "$recovery_mod/partition.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-userdata-checkpoint.patch"

# The UI autosaves during startup, before /data is necessarily mounted; without
# a load-first guard those session defaults overwrite the stored preferences.
grep -q 'gPreferencesLoaded' "$recovery_mod/aeraui/platform/aera_backend.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/aeraui-preferences-persistence.patch"

# Touch must wake the display, otherwise a blanked screen ignores touches while
# hardware keys still work.
grep -q 'A touch is a wake gesture' "$recovery_mod/aeraui/core/runner.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/aeraui-touch-wake.patch"

# charger polls a health HAL that recovery does not have (1 s block per try).
grep -q 'Not started in recovery: charger polls' "$recovery_mod/etc/init.rc" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-stop-charger.patch"

# Fades call Set_Brightness per frame; throttle its logging.
grep -q 'last_logged' "$recovery_mod/twrp-functions.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-brightness-log-throttle.patch"

# Point the in-recovery update check at our own catalog instead of
# aera-recovery.com.
grep -q 'rom.flac.moe/bronco/recovery/aera' "$recovery_mod/aeraui/features/update/update_manager.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/aeraui-update-catalog-url.patch"

# Format Data needs the crypto consumers stopped before mkfs.f2fs.
grep -q 'keystore2 -> /data/misc/keystore' "$recovery_mod/aeraui/platform/aera_backend.cpp" ||
    git -C "$recovery_mod" apply "$root_dir/patches/recovery-format-data-unmount.patch"

# The installer zip's debug vars dump would otherwise list the builder's
# absolute tree path.
vendor_recovery="$aera_dir/vendor/recovery"
grep -q "/AERA_DIR/d" "$vendor_recovery/AERA_A16.sh" ||
    git -C "$vendor_recovery" apply "$root_dir/patches/recovery-build-vars-redact.patch"

cd "$aera_dir"

# Stale artifacts from earlier configurations are never pruned from the recovery
# root: a duplicate boot-HAL manifest fragment (VintfObjectRecovery merges every
# fragment) and usb-mode.sh, which raced init.rc's gadget handling.
rm -f \
    "out/target/product/bronco/recovery/root/system/etc/vintf/manifest/android.hardware.boot-service.qti.xml" \
    "out/target/product/bronco/recovery/root/system/bin/usb-mode.sh"

# Keep the build host out of ro.build.user/ro.build.host in the published image.
export BUILD_USERNAME=aera
export BUILD_HOSTNAME=aera

export AERA_BUILD_DEVICE=bronco
# shellcheck disable=SC1091
source build/envsetup.sh
lunch twrp_bronco-bp2a-eng
mka adbd recoveryimage

printf 'Recovery image: %s\n' "$aera_dir/out/target/product/bronco/AERA-R1.0-Beta-Official-bronco.img"
