#!/system/bin/sh
# Hand /vendor and /vendor_dlkm back to TWRP and the ROM installers.
#
# wlan-start.sh deliberately does not leave either partition mounted: the WLAN
# modules are loaded from a private mount that is released immediately, and
# cnss-daemon/wpa_supplicant run from the recovery ramdisk. This hook therefore
# only has to release mounts that TWRP itself left behind - it must not stop the
# Wi-Fi stack, or a zip install would kill the connection it is using.
#
# /mnt/vendor/persist stays mounted: sec_nvm/spdaemon own the SPU NVM there and
# unmounting it under them risks a half-written NVM transaction. It is exposed
# to TWRP at /persist via a bind mount instead (see spss-start.sh).
#
# Trigger: setprop aera.release.mounts 1
LOG=/tmp/release-mounts.log
: > "$LOG"
log() {
    echo "release-mounts: $*" >> "$LOG"
    echo "release-mounts: $*" > /dev/kmsg 2>/dev/null
}

# Child mounts under /vendor (for example a stale /vendor/firmware_mnt) make
# the parent busy. Recovery no longer creates any, but TWRP may have.
for mnt in $(grep ' /vendor/' /proc/mounts | awk '{print $2}' | sort -r); do
    umount "$mnt" 2>/dev/null && log "unmounted $mnt"
done

if grep -q ' /vendor_dlkm ' /proc/mounts; then
    if umount /vendor_dlkm 2>/dev/null; then
        log "/vendor_dlkm unmounted"
    else
        umount -l /vendor_dlkm 2>/dev/null
        log "/vendor_dlkm lazy-unmounted"
    fi
fi

if grep -q ' /vendor ' /proc/mounts; then
    if umount /vendor 2>/dev/null; then
        log "/vendor unmounted"
    else
        umount -l /vendor 2>/dev/null
        log "/vendor lazy-unmounted"
    fi
fi

log "remaining vendor mounts: $(grep -c ' /vendor ' /proc/mounts)"
log "wifi: cnss=$(pidof cnss-daemon) wpa=$(pidof wpa_supplicant)"
setprop aera.mounts.released 1
