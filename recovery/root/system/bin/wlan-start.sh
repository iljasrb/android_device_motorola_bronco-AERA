#!/system/bin/sh
# Load the QCA6490 WLAN stack in recovery without leaving /vendor mounted.
#
# First-stage init loads cnss2/icnss2 from the vendor_boot ramdisk before
# /vendor exists, so their firmware lookup fails. The modules must NOT be
# unloaded: after probing, the PCIe link is powered down and a fresh insmod
# fails ("PCI device ID mismatch", probe error -5). Instead, mount the vendor
# partitions only long enough to copy the config and load qca_cld3, then
# unmount them. cnss-daemon and its library closure run from the recovery
# ramdisk, so TWRP can mount/unmount /vendor while installing a zip even while
# Wi-Fi stays connected.
#
# Started by crypto-start.sh after /data is mounted: bringing WLAN up before
# the metadata key upgrade makes the upgrade fail.

LOG=/tmp/wlan-start.log
: > "$LOG"

log() {
    echo "wlan-start: $*" >> "$LOG"
    echo "wlan-start: $*" > /dev/kmsg 2>/dev/null
}

slot=$(getprop ro.boot.slot_suffix)
[ -n "$slot" ] || slot=_a

mount_ro() {
    # mount_ro <device> <dir>
    grep -q " $2 " /proc/mounts && return 0
    mkdir -p "$2"
    mount -o ro "$1" "$2" 2>/dev/null && return 0
    mount -t erofs -o ro "$1" "$2" 2>/dev/null && return 0
    mount -t ext4 -o ro "$1" "$2" 2>/dev/null && return 0
    return 1
}

# Mount the vendor images at private paths. Nothing executes from these mounts;
# they are removed before cnss-daemon/wpa_supplicant are started.
vendor_tmp=/tmp/wlan-vendor
dlkm_tmp=/tmp/wlan-dlkm
i=0
while : ; do
    mount_ro "/dev/block/mapper/vendor$slot" "$vendor_tmp"
    mount_ro "/dev/block/mapper/vendor_dlkm$slot" "$dlkm_tmp"
    [ -e "$vendor_tmp/etc/wifi/qca6490/WCNSS_qcom_cfg.ini" ] &&
        [ -e "$dlkm_tmp/lib/modules/qca_cld3_qca6490.ko" ] && break
    if [ "$i" -ge 300 ]; then
        log "vendor/vendor_dlkm did not become available"
        break
    fi
    sleep 0.2
    i=$((i + 1))
done

modules="$dlkm_tmp/lib/modules"
[ -e "$modules/qca_cld3_qca6490.ko" ] || modules="$vendor_tmp/lib/modules"

# The modem partition carries the WLAN firmware (bdwlan.*, wlanData). spss-start
# normally mounts it at /firmware; do it here too if that has not happened.
if [ ! -e /firmware/image ]; then
    i=0
    while [ "$i" -lt 100 ]; do
        for dev in "/dev/block/by-name/modem$slot" /dev/block/by-name/modem_a /dev/block/by-name/modem_b; do
            [ -e "$dev" ] || continue
            mkdir -p /firmware
            mount -o ro "$dev" /firmware 2>/dev/null && break
        done
        [ -e /firmware/image ] && break
        sleep 0.2
        i=$((i + 1))
    done
fi
[ -e /firmware/image ] && log "firmware mounted at /firmware" ||
    log "firmware partition did not become available"

# Recovery has no DMS service, so cnss2 falls back to a random MAC on every
# boot. TWRP's Wlan::Init() prepares a firmware file before the module is
# loaded, but the vendor config does not enable reading it. Copy the config into
# the ramdisk (/vendor is a tmpfs directory here) with
# read_mac_addr_from_mac_file=1 and write our own wlan_mac.bin on a tmpfs over
# the persist copy, so the factory MAC from the kernel command line is used.
prepare_mac() {
    mac_hex=$(tr ' ' '\n' < /proc/cmdline |
        sed -n 's/^wifimacaddr=\([0-9A-Fa-f:]*\).*/\1/p' | head -n 1 | tr -d ':')
    [ ${#mac_hex} -eq 12 ] || { log "no factory MAC in cmdline"; return 1; }
    mac_hex=$(echo "$mac_hex" | tr 'a-f' 'A-F')

    cfg_src=$vendor_tmp/etc/wifi/qca6490/WCNSS_qcom_cfg.ini
    [ -e "$cfg_src" ] || { log "WCNSS_qcom_cfg.ini not found"; return 1; }
    cfg=/vendor/etc/wifi/qca6490/WCNSS_qcom_cfg.ini
    mkdir -p /vendor/etc/wifi/qca6490
    added=
    while IFS= read -r line; do
        if [ -z "$added" ] && [ "$line" = "END" ]; then
            echo "read_mac_addr_from_mac_file=1"
            added=1
        fi
        echo "$line"
    done < "$cfg_src" > "$cfg"
    [ -n "$added" ] || echo "read_mac_addr_from_mac_file=1" >> "$cfg"

    mkdir -p /mnt/vendor/persist/qca6490
    grep -q ' /mnt/vendor/persist/qca6490 ' /proc/mounts ||
        mount -t tmpfs tmpfs /mnt/vendor/persist/qca6490 2>>"$LOG"
    printf 'Intf0MacAddress=%s\nEND\n' "$mac_hex" \
        > /mnt/vendor/persist/qca6490/wlan_mac.bin

    # qca_cld3 reads its INI and MAC file through the firmware loader. In stock
    # Android these live in /vendor/firmware/wlan/qca_cld/qca6490 (the vendor
    # image only carries symlinks into /vendor/etc and /mnt/vendor/persist).
    # /vendor here is a tmpfs, so materialise the same layout in RAM; the
    # private vendor mount is not needed after this point.
    fwdir=/vendor/firmware/wlan/qca_cld/qca6490
    mkdir -p "$fwdir"
    cp "$cfg" "$fwdir/WCNSS_qcom_cfg.ini"
    cp /mnt/vendor/persist/qca6490/wlan_mac.bin "$fwdir/wlan_mac.bin"
    chmod 0644 "$fwdir/WCNSS_qcom_cfg.ini"
    chmod 0666 "$fwdir/wlan_mac.bin"

    log "prepared stable MAC $mac_hex"
}

prepare_mac || true

# cnss-daemon needs its socket directory before it can bind cnss_user_server.
mkdir -p /data/vendor/wifi/sockets /data/vendor/wifi/wpa/sockets
chown -R system:system /data/vendor/wifi
chmod 0770 /data/vendor/wifi/sockets
# wpa_cli creates its client socket here while running as the wifi user.
chmod 0777 /data/vendor/wifi/wpa/sockets

# Stock init writes fs_ready at post-fs-data, before the vendor_dlkm WLAN
# modules are loaded. cnss2 only starts the firmware download after this point,
# so publish fs_ready (and start the calibration daemon) before probing
# qca_cld3. Doing it afterwards leaves the PCIe device without firmware and
# wlan0 never appears.
i=0
while [ ! -e /sys/kernel/cnss/fs_ready ] && [ "$i" -lt 300 ]; do
    sleep 0.2
    i=$((i + 1))
done
if [ -e /sys/kernel/cnss/fs_ready ]; then
    setprop ctl.start cnss-daemon
    i=0
    while [ "$(getprop init.svc.cnss-daemon)" != "running" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    log "cnss-daemon=$(getprop init.svc.cnss-daemon)"
    echo 1 > /sys/kernel/cnss/fs_ready 2>>"$LOG"
    log "cnss fs_ready set before qca_cld3 load"
else
    log "cnss2 did not expose fs_ready"
fi

# cnss2/icnss2 are already loaded by first-stage init. Load the host driver
# only; its init needs the firmware and config paths prepared above. Pass
# fwpath explicitly: the module default is empty, and qca_cld3 then cannot
# find the INI/MAC files we staged under /vendor/firmware.
if [ -e /sys/module/qca_cld3_qca6490/parameters/fwpath ]; then
    echo /vendor/firmware > /sys/module/qca_cld3_qca6490/parameters/fwpath 2>/dev/null
fi
if grep -q "^qca_cld3_qca6490 " /proc/modules; then
    log "qca_cld3 already loaded"
else
    if insmod "$modules/qca_cld3_qca6490.ko" fwpath=/vendor/firmware 2>>"$LOG"; then
        log "loaded qca_cld3"
    else
        log "insmod qca_cld3 failed"
    fi
fi
grep -q "^rmnet_wlan " /proc/modules ||
    insmod "$modules/rmnet_wlan.ko" 2>>"$LOG"

# Release the private vendor mounts now that the module is in memory and the
# config/MAC files live in the ramdisk and on tmpfs. This is the whole point of
# the RAM-copy arrangement: TWRP must be able to unmount /vendor and
# /vendor_dlkm while Wi-Fi is up.
umount "$vendor_tmp" 2>/dev/null
umount "$dlkm_tmp" 2>/dev/null
log "vendor mounts released: vendor=$(grep -c ' /vendor ' /proc/mounts) dlkm=$(grep -c ' /vendor_dlkm ' /proc/mounts)"

i=0
while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 300 ]; do
    sleep 0.2
    i=$((i + 1))
done

if [ -e /sys/class/net/wlan0 ]; then
    ifconfig wlan0 up 2>>"$LOG"
    log "wlan0 is up, mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)"
    # wpa_supplicant drops to the wifi uid in os_program_init(); TWRP creates
    # /tmp/recovery with mode 0700, which would make the control socket
    # unreachable ("mkdir: Permission denied") for that user. Create the tree
    # explicitly (init's umask would make the parent 0700) and then relax it.
    mkdir -p /tmp/recovery/sockets
    chmod 0755 /tmp/recovery
    # wpa_supplicant drops to the wifi uid and chmods its control directory;
    # that fails unless the directory is owned by wifi.
    chown wifi:wifi /tmp/recovery/sockets
    chmod 0777 /tmp/recovery/sockets
    # Start the supplicant now so TWRP's WLAN page finds it already running.
    # The sys.aera.wlan.up trigger restarts it after a Disable/Enable cycle.
    setprop ctl.start wpa_supplicant
else
    log "wlan0 did not appear"
fi

log "done"
