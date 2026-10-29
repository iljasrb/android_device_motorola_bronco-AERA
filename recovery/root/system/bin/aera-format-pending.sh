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
    # A metadata-encrypted /data must NOT be mkfs'd here. AOSP recovery's
    # format_volume() (recovery_utils/roots.cpp) only zeroes the partition for
    # this case and lets vold create the filesystem, the keyblob and the f2fs
    # layout on first boot. A pre-made bare f2fs is exactly what Android rejects
    # with "Can't load Android system. Your data may be corrupt", which then
    # requires a factory reset from a stock recovery.
    # Same sequence as AOSP's wipe_block_device() (ext4_utils/wipe.cpp): secure
    # discard, then discard, and only if both fail write 4096 zero bytes. A byte
    # loop over 234 GB takes minutes and hangs recovery on a black screen.
    if blkdiscard -s $USERDATA 2>/dev/null; then
        echo "aera-format: userdata secure-discarded" > /dev/kmsg 2>/dev/null
    elif blkdiscard $USERDATA 2>/dev/null; then
        echo "aera-format: userdata discarded" > /dev/kmsg 2>/dev/null
    else
        dd if=/dev/zero of=$USERDATA bs=4096 count=1 2>/dev/null || exit 1
        echo "aera-format: userdata discard failed, wrote zero superblock" > /dev/kmsg 2>/dev/null
    fi
    sync
    # /metadata must end up as a *fresh* filesystem, not a half-destroyed one.
    # Zeroing the ext4 superblock leaves the old keyring blobs intact and vold
    # then cannot set metadata encryption up, which makes Android reboot to
    # recovery ~30 s into boot with no log at all. Stock recovery formats it.
    umount /metadata 2>/dev/null
    mkdir -p /mnt/newmeta
    if mke2fs -t ext4 -F -b 4096 -I 512 -L metadata $META >/dev/null 2>&1; then
        echo "aera-format: metadata formatted as ext4" > /dev/kmsg 2>/dev/null
    else
        # Fall back to a full wipe: vold formats it on first boot anyway, but a
        # zeroed keyring area is the difference between booting and not booting.
        dd if=/dev/zero of=$META bs=1M count=16 2>/dev/null || exit 1
        echo "aera-format: metadata zeroed (mke2fs failed)" > /dev/kmsg 2>/dev/null
    fi
    # Nothing may be left asking the bootloader for a recovery boot.
    dd if=/dev/zero of=/dev/block/by-name/misc bs=1024 count=1 2>/dev/null
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
