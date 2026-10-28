#!/system/bin/sh
# Boot the remote processors that recovery needs but that init does not start
# on its own, and bring up QSEECom in the right order.
#
# 188101c.remoteproc-spss -- the SPU (secure processor).
#   Stock Android has it running; in recovery it stays 'detached', so the
#   secure processor is unavailable, gatekeeper's verify_legacy returns -45,
#   keystore2 then reports KEY_USER_NOT_AUTHENTICATED and user-0 (CE)
#   decryption fails.
#
# 3000000.remoteproc-adsp -- the ADSP.
#   The Qualcomm charger stack (qti_glink_charger + battery_charger over
#   glink) runs on the ADSP. Without it /sys/class/power_supply/battery never
#   appears, healthd reports "No battery devices found", and TWRP either shows
#   -1% (legacy sysfs path) or a fake 100% (health HAL). The only node left,
#   mmi_battery, reports capacity 100 / status Unknown and is useless.
#
#   The ADSP firmware MUST be reachable at /firmware/image, because that is the
#   path ueventd tries ("ueventd: firmware: attempted /firmware/image/adsp.mdt").
#   Mount the modem partition only at /firmware. Do NOT also mount it under
#   /vendor/firmware_mnt: that child mount makes "umount /vendor" fail with
#   EBUSY while TWRP installs a zip.
export PATH=/system/bin:/sbin

LOG=/tmp/spss-start.log
: > "$LOG"
log() {
    echo "spss-start: $*" >> "$LOG"
    echo "spss-start: $*" > /dev/kmsg 2>/dev/null
}

wait_for() {
    # wait_for <path> [ticks of 0.1s]
    i=0
    limit=${2:-100}
    while [ ! -e "$1" ] && [ "$i" -lt "$limit" ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -e "$1" ]
}

slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
[ -n "$slot" ] || slot=_b

# The recovery ueventd rules live in /vendor/etc/ueventd.rc (imported by
# /system/etc/ueventd.rc), but apply the ownership again once the nodes exist:
# qseecomd runs as system and /dev/qsee_ipc_irq_spss must be system:drmrpc 0660
# or the SPU<->TEE IPC fails and the gatekeeper TA answers -2 (retry) to every
# verify, whatever the credential.
fix_node() {
    [ -e "$1" ] || return 0
    chown "$2:$3" "$1" 2>/dev/null
    chmod "$4" "$1" 2>/dev/null
}

for node in /dev/qseecom /dev/qce /dev/smcinvoke /dev/qsee_ipc_irq_spss /dev/pft; do
    wait_for "$node" 100
    fix_node "$node" system drmrpc 0660
done
for node in /dev/spcom /dev/spss_utils /dev/sp_kernel /dev/sp_nvm /dev/sp_ssr \
            /dev/sp_keymaster /dev/sp_keymaster_ssr /dev/cryptoapp \
            /dev/spdaemon_ssr /dev/spu_hal_ssr; do
    fix_node "$node" system system 0660
done
for node in /dev/adsprpc-smd; do
    fix_node "$node" system system 0664
done
for node in /dev/adsprpc-smd-secure; do
    fix_node "$node" system system 0644
done
for node in /dev/wlan; do
    fix_node "$node" wifi wifi 0660
done

# qseecomd is started by init from on fs. Only fall back to starting it here if
# it is missing; do not wait for its listeners, because that wait would delay
# this script (and the SPSS) without gating anything - crypto.ready is set by
# prepdecrypt independently.
if [ "$(getprop init.svc.qseecomd)" != "running" ]; then
    setprop ctl.start qseecomd
fi
log "qseecomd=$(getprop init.svc.qseecomd) listeners=$(getprop vendor.sys.listeners.registered)"

# Make the ADSP/SPSS firmware loadable before anything asks a remoteproc to
# boot. /firmware is the only modem mount recovery needs; keeping it out of
# /vendor lets TWRP unmount vendor partitions while a zip is being installed.
if [ ! -e /firmware/image ]; then
    i=0
    while [ "$i" -lt 100 ]; do
        for dev in "/dev/block/by-name/modem$slot" /dev/block/by-name/modem_a /dev/block/by-name/modem_b; do
            [ -e "$dev" ] || continue
            mkdir -p /firmware
            mount -o ro "$dev" /firmware 2>/dev/null && break
        done
        [ -e /firmware/image ] && break
        sleep 0.1
        i=$((i + 1))
    done
fi
[ -e /firmware/image ] && log "modem firmware mounted at /firmware" ||
    log "modem firmware did not appear at /firmware"

# spdaemon and sec_nvm keep the SPU's persistent state in /mnt/vendor/persist.
# Android mounts the real persist partition there in post-fs; recovery must do
# the same, otherwise the SPU NVM is an empty tmpfs and the gatekeeper TA
# answers ERROR_RETRY_TIMEOUT (-2) to every verify, even though the identical
# request succeeds in Android. Mount it read-write like Android does: sec_nvm
# updates the transaction counters of the NVM segments.
mkdir -p /mnt/vendor/persist
mount -o rw /dev/block/by-name/persist /mnt/vendor/persist 2>/dev/null
mkdir -p /mnt/vendor/persist/secnvm /mnt/vendor/persist/iar_db
chown system:system /mnt/vendor/persist/secnvm /mnt/vendor/persist/iar_db 2>/dev/null
# TWRP's fstab wants /persist mounted directly; it cannot (the device is already
# mounted here), which makes TWRP log "Unable to mount '/persist'" and skip
# persist operations. Expose the same mount under /persist so they work, while
# sec_nvm/spdaemon keep owning the NVM underneath.
mkdir -p /persist
mount -o bind /mnt/vendor/persist /persist 2>/dev/null

# The spss_utils kernel probe registers remoteproc0 asynchronously. Writing
# 'start' before that node exists silently does nothing, and the SPSS then only
# reaches phase 1: it never signals the spcom 'SPU ready' event, so the vendor
# gatekeeper HAL blocks forever in spu_init() waiting for the SPSS 'cryptoapp'
# server. Wait for the node, then start it.
i=0
spss=""
while [ "$i" -lt 100 ]; do
    for r in /sys/class/remoteproc/*/; do
        if [ "$(cat "$r/name" 2>/dev/null)" = "188101c.remoteproc-spss" ]; then
            spss="$r"
            break
        fi
    done
    [ -n "$spss" ] && break
    sleep 0.2
    i=$((i + 1))
done
log "spss remoteproc: ${spss:-not found}"

# Stock Android lets spdaemon bring the SPSS up itself: from post-fs init
# starts vendor.spdaemon and vendor.sec_nvm, and spdaemon does the remoteproc
# attach, the PBL/2nd-phase load and the spcom 'FW loading process is
# complete' handshake (visible as "attaching to 188101c.remoteproc-spss" from
# spdaemon's own pid). Writing 'start' to the remoteproc sysfs from a shell is
# a different path and leaves the SPU half-initialised - spdaemon then reports
# "-12" instead of stock's benign "-11" and the gatekeeper TA answers -2.
setprop ctl.start spdaemon
setprop ctl.start sec_nvm
i=0
while [ "$(getprop init.svc.spdaemon)" != "running" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
log "spdaemon/sec_nvm started: spdaemon=$(getprop init.svc.spdaemon) sec_nvm=$(getprop init.svc.sec_nvm)"

# The ADSP still has to be started from here (spdaemon only owns the SPSS); the
# charger stack runs on it.
for r in /sys/class/remoteproc/*/; do
    case "$(cat "$r/name" 2>/dev/null)" in
        3000000.remoteproc-adsp)
            echo start > "$r/state" 2>/dev/null
            ;;
    esac
done

# Wait for spdaemon to finish the SPSS bring-up.
i=0
while [ "$i" -lt 150 ]; do
    dmesg 2>/dev/null | grep -q 'SW_INIT_DONE' && break
    sleep 0.2
    i=$((i + 1))
done
if ! dmesg 2>/dev/null | grep -q 'SW_INIT_DONE'; then
    log "spdaemon did not bring the SPSS up; falling back to a sysfs start"
    for r in /sys/class/remoteproc/*/; do
        case "$(cat "$r/name" 2>/dev/null)" in
            188101c.remoteproc-spss)
                echo start > "$r/state" 2>/dev/null
                ;;
        esac
    done
    i=0
    while [ "$i" -lt 100 ]; do
        dmesg 2>/dev/null | grep -q 'SW_INIT_DONE' && break
        sleep 0.2
        i=$((i + 1))
    done
fi
log "spdaemon attach: $(dmesg 2>/dev/null | grep -c 'attaching to 188101c.remoteproc-spss') attach markers"

if dmesg 2>/dev/null | grep -q 'SW_INIT_DONE'; then
    log "SPSS 2nd phase loaded"
else
    log "SPSS 2nd phase not confirmed; continuing"
fi

setprop aera.spss.ready 1
