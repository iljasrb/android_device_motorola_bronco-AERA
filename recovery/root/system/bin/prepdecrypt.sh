#!/system/bin/sh
# Load the installed ROM's OS/security patch properties before KeyMint starts.
#
# The recovery image is built with placeholder values (2099-12-31). KeyMint
# uses the vendor security patch level when it upgrades the hardware-wrapped
# metadata keyblob, so starting it with a placeholder can make that upgrade
# invalid and leave /data unmountable. AERA's reference trees solve this with
# prepdecrypt.sh + crypto.ready; this is the bronco equivalent.
#
# bronco's logical partitions are mapped by TWRP, not by recovery init, so wait
# for the mapper devices instead of creating a competing dm table. Mounting the
# same read-only image a second time is safe; TWRP's mounts are left alone.

LOG=/tmp/prepdecrypt.log
: > "$LOG"

log() {
    echo "prepdecrypt: $*" >> "$LOG"
    echo "prepdecrypt: $*" > /dev/kmsg 2>/dev/null
}

slot=$(getprop ro.boot.slot_suffix)
[ -n "$slot" ] || slot="_$(getprop ro.boot.slot)"
[ -n "$slot" ] || slot=_a

wait_for() {
    # wait_for <path> [ticks of 0.1s]
    i=0
    limit=${2:-150}
    while [ ! -e "$1" ] && [ "$i" -lt "$limit" ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -e "$1" ]
}

read_prop() {
    # read_prop <build.prop> <key>
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

set_prop() {
    # set_prop <key> <value>
    [ -n "$2" ] || return 0
    if [ -x /system/bin/resetprop ]; then
        /system/bin/resetprop "$1" "$2"
    else
        setprop "$1" "$2" 2>/dev/null
    fi
}

mount_ro() {
    # mount_ro <device> <dir>
    mkdir -p "$2" 2>/dev/null || return 1
    mount -o ro "$1" "$2" 2>/dev/null && return 0
    mount -t ext4 -o ro "$1" "$2" 2>/dev/null && return 0
    mount -t erofs -o ro "$1" "$2" 2>/dev/null && return 0
    return 1
}

vendor_dev="/dev/block/mapper/vendor$slot"
system_dev="/dev/block/mapper/system$slot"

if wait_for "$vendor_dev"; then
    if mount_ro "$vendor_dev" /tmp/prepdecrypt/vendor; then
        vendor_patch=$(read_prop /tmp/prepdecrypt/vendor/build.prop ro.vendor.build.security_patch)
        set_prop ro.vendor.build.security_patch "$vendor_patch"
        log "vendor security patch: ${vendor_patch:-not found}"
        umount /tmp/prepdecrypt/vendor 2>/dev/null
        rmdir /tmp/prepdecrypt/vendor 2>/dev/null
    else
        log "cannot mount $vendor_dev"
    fi
else
    log "$vendor_dev did not appear"
fi

if wait_for "$system_dev" 50; then
    if mount_ro "$system_dev" /tmp/prepdecrypt/system; then
        prop=/tmp/prepdecrypt/system/system/build.prop
        [ -f "$prop" ] || prop=/tmp/prepdecrypt/system/build.prop
        system_release=$(read_prop "$prop" ro.build.version.release)
        system_patch=$(read_prop "$prop" ro.build.version.security_patch)
        set_prop ro.build.version.release "$system_release"
        set_prop ro.build.version.security_patch "$system_patch"
        log "system release/patch: ${system_release:-not found}/${system_patch:-not found}"
        umount /tmp/prepdecrypt/system 2>/dev/null
        rmdir /tmp/prepdecrypt/system 2>/dev/null
    else
        log "cannot mount $system_dev"
    fi
else
    log "$system_dev did not appear"
fi

# Make AERA's live-fastbootd hook recognise this device. It looks for
# /vendor/bin/prepdecrypt.sh, prepdecrypt.setpatch, or a prepdecrypt.vendor
# service before waiting for crypto.ready.
setprop prepdecrypt.setpatch 1

# Release keymint even when a mount failed: decryption must still be attempted,
# and crypto-start.sh restarts the TEE/keystore pair after the first pass.
# Do not wait for qseecomd or the TEE listeners here: keystore2 is started by
# its own rc as soon as qseecomd registers, and keymint must follow immediately
# so keystore2 finds the AIDL service. Waiting here reintroduces the #35 race.
setprop crypto.ready 1
log "crypto.ready=$(getprop crypto.ready)"
