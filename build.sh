#!/usr/bin/env bash
# Build AERA recovery for bronco.
#
#   AERA_DIR=~/aera_16.0 ./build.sh [options]
#
# Installs this tree into $AERA_DIR/device/motorola/bronco, applies the patches
# in patches/, and builds recoveryimage.
set -eo pipefail
# not -u: AOSP's envsetup.sh/lunch reference unbound variables (TOP).

readonly root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly aera_dir="${AERA_DIR:?set AERA_DIR to a synced aera_16.0 checkout}"
readonly dest_tree="$aera_dir/device/motorola/bronco"

jobs="$(nproc)"
clean=false
enable_ccache=false
patches_only=false
sync_checkout=false

usage() {
    cat <<EOF
Usage: AERA_DIR=... $0 [options]

Options:
  -j, --jobs N       Build with N jobs (default: $(nproc))
      --clean        Remove the AERA out/ tree before building
      --ccache       Enable ccache when it is installed
      --patches-only Install the device tree and apply patches, then stop
      --sync         Update the AERA checkout with repo sync first
  -h, --help         Show this help
EOF
}

while (($#)); do
    case "$1" in
        -j|--jobs)
            jobs="${2:?--jobs needs a value}"
            shift 2
            ;;
        --clean)
            clean=true
            shift
            ;;
        --ccache)
            enable_ccache=true
            shift
            ;;
        --patches-only)
            patches_only=true
            shift
            ;;
        --sync)
            sync_checkout=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid job count: %s\n' "$jobs" >&2
    exit 2
}

[[ -f "$aera_dir/build/envsetup.sh" ]] || {
    printf 'AERA_DIR (%s) is not a synced aera_16.0 checkout\n' "$aera_dir" >&2
    exit 1
}

# Keep grep/sort/awk deterministic and slightly faster on non-English hosts.
export LC_ALL=C

if $sync_checkout; then
    if command -v repo >/dev/null 2>&1; then
        printf 'Syncing AERA checkout at %s ...\n' "$aera_dir"
        (cd "$aera_dir" && repo sync -d -j"$jobs")
    else
        printf 'repo is not installed; update %s manually or install repo.\n' \
            "$aera_dir" >&2
        exit 1
    fi
fi

if $clean; then
    printf 'Removing %s/out ...\n' "$aera_dir"
    rm -rf "$aera_dir/out"
fi

if $enable_ccache; then
    if command -v ccache >/dev/null 2>&1; then
        export USE_CCACHE=1
        export CCACHE_EXEC="$(command -v ccache)"
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        printf 'ccache enabled: %s (%s)\n' "$CCACHE_EXEC" "$CCACHE_DIR"
    else
        printf 'ccache requested but not installed; continuing without it.\n' >&2
    fi
fi

tree_files=(
    Android.bp
    Android.mk
    AndroidProducts.mk
    BoardConfig.mk
    device.mk
    aera_bronco.mk
    twrp_bronco.mk
    recovery.fstab
    gpu
    system.prop
    vendorsetup.sh
    recovery
)

# rsync preserves unchanged timestamps, so an incremental build only notices the
# files that actually changed. The rm -rf + cp -a path is the portable fallback.
install_tree() {
    local entry name keep
    if command -v rsync >/dev/null 2>&1; then
        mkdir -p "$dest_tree"
        # Drop top-level entries that are no longer part of the tree.
        for entry in "$dest_tree"/* "$dest_tree"/.[!.]*; do
            [[ -e "$entry" ]] || continue
            keep=false
            for name in "${tree_files[@]}"; do
                if [[ "$(basename "$entry")" == "$name" ]]; then
                    keep=true
                    break
                fi
            done
            $keep || rm -rf "$entry"
        done
        for name in "${tree_files[@]}"; do
            if [[ -d "$root_dir/$name" ]]; then
                # busybox is installed below, not part of the source tree; keep
                # it across incremental installs so its timestamp stays stable.
                rsync -a --delete --exclude=root/system/bin/busybox \
                    "$root_dir/$name/" "$dest_tree/$name/"
            else
                rsync -a "$root_dir/$name" "$dest_tree/"
            fi
        done
    else
        rm -rf "$dest_tree"
        mkdir -p "$dest_tree"
        cp -a "${tree_files[@]/#/$root_dir/}" "$dest_tree"/
    fi
}

# Apply a patch once. The marker check covers patches that are already applied
# and whose context has since been moved by a later patch in the same file.
patch_repo() {
    local repo="$1"
    local patch="$2"
    local marker_file="$3"
    local marker="$4"
    local name
    name="$(basename "$patch")"

    if [[ -n "$marker_file" ]] &&
        grep -qF -- "$marker" "$repo/$marker_file" 2>/dev/null; then
        printf '  %-48s already applied\n' "$name"
        return 0
    fi
    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '  %-48s already applied\n' "$name"
        return 0
    fi
    if ! git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        printf 'ERROR: %s no longer applies to %s\n' "$name" "$repo" >&2
        git -C "$repo" apply --check "$patch" >&2 || true
        exit 1
    fi
    git -C "$repo" apply "$patch"
    printf '  %-48s applied\n' "$name"
}

install_tree
printf 'Installed device tree at %s\n' "$dest_tree"

# AERA's plugin store, updater and font downloader call `busybox wget`; the AERA
# ramdisk script drops /sbin/busybox, so install the vendored static busybox at
# the documented fallback path.
busybox="$aera_dir/vendor/recovery/prebuilt/arm64/busybox"
[[ -f "$busybox" ]] || {
    printf 'Missing vendored busybox: %s\n' "$busybox" >&2
    exit 1
}
busybox_dest="$dest_tree/recovery/root/system/bin/busybox"
if ! cmp -s "$busybox" "$busybox_dest"; then
    install -D -m 0755 "$busybox" "$busybox_dest"
fi

# The patched repositories must exist before git apply runs.
for repo in system/security/keystore2 system/libhidl system/core \
    bootable/recovery vendor/recovery; do
    git -C "$aera_dir/$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        printf 'Missing git repository: %s\n' "$aera_dir/$repo" >&2
        exit 1
    }
done

ks2="$aera_dir/system/security/keystore2"
hidl="$aera_dir/system/libhidl"
core="$aera_dir/system/core"
recovery_mod="$aera_dir/bootable/recovery"
vendor_recovery="$aera_dir/vendor/recovery"

# A16 keystore2 sends the operation NONCE to KeyMint upgradeKey(); the vendor TA
# rejects it with INVALID_ARGUMENT and A17-encrypted /data does not mount.
patch_repo "$ks2" "$root_dir/patches/keystore2-strip-nonce-from-upgrade.patch" \
    src/utils.rs filtered_params

# Recovery resolves HIDL to passthrough; ENFORCE_VINTF_MANIFEST rejects the
# gatekeeper registration and the vendor HAL is unreachable.
#
# SECURITY: this disables a VINTF manifest check in libhidl. It is required for
# gatekeeper passthrough in recovery; never widen it beyond libhidl's default
# cflags block.
patch_repo "$hidl" \
    "$root_dir/patches/libhidl-recovery-passthrough-no-vintf-enforce.patch" \
    Android.bp 'libhidl still resolves'

# fastbootd resolves health/fastboot HALs while USB is still closed; recovery has
# neither, so the blocking waits hang the daemon and USB never re-enumerates.
patch_repo "$core" "$root_dir/patches/fastbootd-hal-nonblocking.patch" \
    fastboot/device/fastboot_device.cpp 'Never wait here: fastbootd is'

# The Adreno path imported gralloc/native-buffer scanouts, but recovery has no
# vendor graphics stack before decryption. Composite into a pbuffer and read the
# frame back into minui's DRM scanout buffer instead.
patch_repo "$recovery_mod" "$root_dir/patches/aeraui-gpu-readback-scanout.patch" \
    aeraui/core/gpu_renderer.cpp 'software-scanout GPU ready'

# The decrypt page is shown before backend_ready_; the pointer gate must not
# swallow its touches.
patch_repo "$recovery_mod" "$root_dir/patches/aeraui-decrypt-touch.patch" \
    aeraui/core/engine.cpp 'The decrypt page runs before backend_ready_'

# Prefer the bootloader's factory wifimacaddr= over the serial-derived MAC.
patch_repo "$recovery_mod" "$root_dir/patches/recovery-wlan-factory-mac.patch" \
    wlan.cpp 'wifimacaddr='

# TestConnection used `busybox ping`, absent here; probe with native sockets.
patch_repo "$recovery_mod" \
    "$root_dir/patches/recovery-wlan-native-connectivity-test.patch" \
    wlan.cpp 'static bool ProbeTcp'

# The Wi-Fi switch consumed the tap, so only the label toggled the radio.
patch_repo "$recovery_mod" "$root_dir/patches/aeraui-wifi-toggle-click.patch" \
    aeraui/scenes/wifi_scene.cpp 'The switch is only an indicator'

# The animated fastboot hand-off segfaulted inside LVGL before
# RecoveryEnterFastbootd(); use a fade, fall back to cold boot-fastboot, and use
# the sys.usb.config.aera_fastbootd marker (ro.* writes are dropped).
patch_repo "$recovery_mod" "$root_dir/patches/aeraui-fastbootd-live-entry.patch" \
    aeraui/core/runner.cpp 'live fastbootd failed; rebooting to cold fastbootd'

# Sideload serves the package over FUSE, which has no random access; the zip
# installer aborted mid-package. Stage it in tmpfs first.
patch_repo "$recovery_mod" \
    "$root_dir/patches/recovery-sideload-stage-package.patch" \
    twrpinstall/adb_install.cpp 'kLocalPackage'

# Recovery pins /vendor for the boot once its libraries are mapped; the zip
# installer refuses to run until /vendor is unmounted. Release it before install.
patch_repo "$recovery_mod" \
    "$root_dir/patches/recovery-release-vendor-mounts.patch" \
    aeraui/platform/aera_backend.cpp 'ReleaseVendorMountsForInstall'

# A VAB ROM install lands on the inactive slot; nothing boots it until the
# bootloader is told. update_engine switches the slot itself, but a zip install
# driven through TWRP's installer needs the same step.
patch_repo "$recovery_mod" \
    "$root_dir/patches/twinstall-switch-slot-after-ota.patch" \
    twrpinstall/twinstall.cpp 'AERA install: switching active slot'

# make_f2fs leaves userdata checkpoint-disabled, so every write made in a
# recovery session was rolled back on the next boot (settings, backups).
patch_repo "$recovery_mod" "$root_dir/patches/recovery-userdata-checkpoint.patch" \
    partition.cpp 'checkpoint=enable'

# A blanked screen ignored touch: every evdev ABS event was dropped while
# screen_off was set, and only hardware keys cleared it.
patch_repo "$recovery_mod" "$root_dir/patches/aeraui-touch-wake.patch" \
    aeraui/core/runner.cpp 'A touch is a wake gesture'

# The transition animation is UI-only; its removal is unrelated to fastbootd.
patch_repo "$recovery_mod" \
    "$root_dir/patches/aeraui-power-transition-simplify.patch" \
    aeraui/components/power_transition.cpp \
    'Keep the hand-off short and deliberately simple'

# The UI autosaves during startup, before /data is necessarily mounted; without
# a load-first guard those session defaults overwrite the stored preferences.
patch_repo "$recovery_mod" \
    "$root_dir/patches/aeraui-preferences-persistence.patch" \
    aeraui/platform/aera_backend.cpp 'gPreferencesLoaded'

# charger polls a health HAL that recovery does not have (1 s block per try).
patch_repo "$recovery_mod" "$root_dir/patches/recovery-stop-charger.patch" \
    etc/init.rc 'Not started in recovery: charger polls'

# Fades call Set_Brightness per frame; throttle its logging.
patch_repo "$recovery_mod" \
    "$root_dir/patches/recovery-brightness-log-throttle.patch" \
    twrp-functions.cpp 'last_logged'

# Point the in-recovery update check at our own catalog instead of
# aera-recovery.com.
patch_repo "$recovery_mod" \
    "$root_dir/patches/aeraui-update-catalog-url.patch" \
    aeraui/features/update/update_manager.cpp \
    'rom.flac.moe/bronco/recovery/aera'

# Format Data needs the crypto consumers stopped before mkfs.f2fs.
patch_repo "$recovery_mod" \
    "$root_dir/patches/recovery-format-data-unmount.patch" \
    aeraui/platform/aera_backend.cpp 'keystore2 -> /data/misc/keystore'

# The installer zip's debug vars dump would otherwise list the builder's
# absolute tree path.
patch_repo "$vendor_recovery" "$root_dir/patches/recovery-build-vars-redact.patch" \
    AERA_A16.sh '/AERA_DIR/d'

if $patches_only; then
    printf 'Device tree installed and patches applied; stopping before the build.\n'
    exit 0
fi

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
mka -j"$jobs" adbd recoveryimage

# The Adreno userspace ships as a prebuilt closure in this tree; a missing
# dependency is invisible at build time and only downgrades the UI to the
# software renderer at runtime, so verify it ends up resolvable in the ramdisk.
recovery_root="$aera_dir/out/target/product/bronco/recovery/root"
command -v readelf >/dev/null 2>&1 || {
    printf 'readelf is required to verify the GPU library closure\n' >&2
    exit 1
}
missing_libs=$(for lib in "$recovery_root"/vendor/lib64/*.so \
        "$recovery_root"/vendor/lib64/egl/*.so "$recovery_root"/vendor/lib64/hw/*.so; do
    for needed in $(readelf -dW "$lib" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
        for dir in "$recovery_root/vendor/lib64" "$recovery_root/vendor/lib64/egl" \
                "$recovery_root/vendor/lib64/hw" "$recovery_root/system/lib64"; do
            [ -e "$dir/$needed" ] && continue 2
        done
        printf '%s needs %s\n' "$(basename "$lib")" "$needed"
    done
done)
[[ -z "$missing_libs" ]] || {
    printf 'GPU library closure is incomplete in %s:\n%s\n' "$recovery_root" "$missing_libs" >&2
    exit 1
}

# KGSL requests these during first-stage init, before /firmware is mounted.
# /etc/firmware stays visible after /vendor is mounted; /vendor/firmware is
# the fallback used by the current GMU blob.
for fw in gmu_gen70000.bin a730_sqe.fw a730_zap.mdt; do
    [[ -e "$recovery_root/vendor/firmware/$fw" ||
       -e "$recovery_root/system/etc/firmware/$fw" ]] || {
        printf 'GPU firmware missing from the ramdisk: %s\n' "$fw" >&2
        exit 1
    }
done

product_dir="$aera_dir/out/target/product/bronco"
image=$(ls -t "$product_dir"/AERA-*.img 2>/dev/null | head -1)
zip=$(ls -t "$product_dir"/AERA-*.zip 2>/dev/null | head -1)
[[ -n "$image" ]] || {
    printf 'No AERA image produced in %s\n' "$product_dir" >&2
    exit 1
}

# AERA_A16.sh writes the md5 with the build path; keep the published sidecars
# relative so they remain valid after copying the artifacts elsewhere.
for artifact in "$image" "$zip"; do
    [[ -n "$artifact" && -f "$artifact" ]] || continue
    ( cd "$product_dir" && md5sum "$(basename "$artifact")" > "$(basename "$artifact").md5" )
done

printf 'Recovery image: %s\n' "$image"
[[ -n "$zip" ]] && printf 'Installer zip: %s\n' "$zip"
