#!/system/bin/sh
# Deferred Format Data.
#
#   aera-format-pending.sh mark   record the request on /metadata
#   aera-format-pending.sh take   format userdata if a request is recorded
#
# Metadata encryption keeps userdata mapped through dm-default-key and the
# kernel holds that mapping open, so mkfs.f2fs cannot take the partition while
# recovery runs decrypted ("Error: In use by the system!"). 'mark' is called
# from the format job; the next recovery boot runs 'take' before the crypto
# chain maps userdata, so mkfs gets the raw partition. /metadata is then
# invalidated so Android recreates the keys for the new filesystem.

META=/dev/block/by-name/metadata
USERDATA=/dev/block/by-name/userdata
MNT=/mnt/metadata
MARKER=$MNT/aera-format-pending

case "$1" in
mark)
    mkdir -p $MNT
    mount -t ext4 -o rw $META $MNT || exit 1
    : > $MARKER || { umount $MNT; exit 1; }
    sync
    umount $MNT
    ;;
take)
    mkdir -p $MNT
    mount -t ext4 -o ro $META $MNT >/dev/null 2>&1 || exit 1
    if [ ! -f $MARKER ]; then
        umount $MNT
        exit 1
    fi
    umount $MNT
    /system/bin/make_f2fs -f -g android -O project_quota,extra_attr \
        -O casefold -C utf8 $USERDATA || exit 1
    # make_f2fs leaves the filesystem in checkpoint-disabled state, which drops
    # every write made in a recovery session on the next boot. Mounting it with
    # checkpoints enabled flips that flag and writes a clean checkpoint.
    mkdir -p /mnt/newdata
    if mount -t f2fs -o rw,checkpoint=enable $USERDATA /mnt/newdata 2>/dev/null; then
        umount /mnt/newdata
    fi
    dd if=/dev/zero of=$META bs=4096 count=4 2>/dev/null || exit 1
    # Persistent record: /persist survives a data wipe and shows up in logs
    # pulled after the reboot.
    mkdir -p /mnt/persist
    if mount -t ext4 -o rw /dev/block/by-name/persist /mnt/persist 2>/dev/null; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) formatted userdata and invalidated /metadata" \
            >> /mnt/persist/aera-format.log
        sync
        umount /mnt/persist
    fi
    sync
    ;;
*)
    echo "usage: $0 mark|take" >&2
    exit 2
    ;;
esac
