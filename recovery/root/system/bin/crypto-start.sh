#!/system/bin/sh
# TEE/keystore bootstrap for recovery.
#
# prepdecrypt.sh loads the installed ROM's real security patch level and sets
# crypto.ready; keymint-qti starts from that property, and keystore2.rc starts
# keystore2 as soon as qseecomd registers its TEE listeners. Because keystore2
# is already waiting for the AIDL KeyMint service, the first Decrypt_Data()
# usually upgrades the wrapped metadata keyblob and mounts /data in one pass.
#
# If it still fails (the old first-QSEECom-handle problem), restart keymint and
# keystore2 and then the recovery binary for one more attempt. Restarting
# recovery after a successful mount unmounts /data, and this baseline cannot
# remount an already-decrypted FBE volume reliably, so never take the retry path
# once metadata is up or TWRP has reached the credential page.

LOG=/tmp/crypto-start.log
: > "$LOG"

# A Format Data request from the previous session is applied here, before this
# chain creates the dm-default-key mapping that makes userdata unformattable.
if /system/bin/aera-format-pending.sh take; then
    # /data is a plain f2fs now and /metadata is blank: nothing to decrypt, so
    # skip the whole crypto chain and let recovery mount userdata directly.
    echo "crypto-start: formatted userdata, continuing without crypto" > /dev/kmsg
    setprop aera.data.formatted 1
    exit 0
fi

log() {
    echo "crypto-start: $*" >> "$LOG"
    echo "crypto-start: $*" > /dev/kmsg 2>/dev/null
}

wait_service() {
    # wait_service <name> <state> [ticks of 0.2s]
    i=0
    limit=${3:-100}
    while [ "$(getprop "init.svc.$1")" != "$2" ] && [ "$i" -lt "$limit" ]; do
        sleep 0.2
        i=$((i + 1))
    done
}

wait_not_running() {
    # wait_not_running <name> [ticks of 0.2s]
    i=0
    limit=${2:-100}
    while [ "$(getprop "init.svc.$1")" = running ] && [ "$i" -lt "$limit" ]; do
        sleep 0.2
        i=$((i + 1))
    done
}

wait_prop() {
    # wait_prop <key> <value> [ticks of 0.2s]
    i=0
    limit=${3:-100}
    while [ "$(getprop "$1")" != "$2" ] && [ "$i" -lt "$limit" ]; do
        sleep 0.2
        i=$((i + 1))
    done
}

keystore_ready() {
    out=$(/system/bin/keystore_cli_v2 list 2>&1)
    case "$out" in
        *Keys:*) return 0 ;;
    esac
    return 1
}

wait_keystore() {
    # wait_keystore [ticks of 0.2s]
    keystore_ticks=0
    limit=${1:-150}
    while [ "$keystore_ticks" -lt "$limit" ]; do
        if keystore_ready; then
            return 0
        fi
        [ "$(getprop init.svc.keystore2)" = "running" ] ||
            setprop ctl.start keystore2
        sleep 0.2
        keystore_ticks=$((keystore_ticks + 1))
    done
    return 1
}

# Wait until TWRP has finished its startup pass before touching the TEE
# (restarting mid-startup leaves the first instance half initialised).
i=0
while ! grep -q 'Process ended with no errors' /tmp/recovery.log && [ "$i" -lt 300 ]; do
    sleep 0.2
    i=$((i + 1))
done

# Give the mount a short grace period; the first Decrypt_Data() can finish just
# before the startup marker.
i=0
while ! grep -q ' /data ' /proc/mounts && [ "$i" -lt 25 ]; do
    sleep 0.2
    i=$((i + 1))
done

if grep -q ' /data ' /proc/mounts; then
    setprop aera.crypto.retries 0
    log "/data mounted on first pass; skipping TEE/recovery restart"
elif grep -q 'Is encrypted, do decrypt page first' /tmp/recovery.log; then
    # Metadata is decrypted and TWRP is on the credential page. The user has
    # not entered a PIN yet; restarting here would unmount /data and loop.
    setprop aera.crypto.retries 0
    log "decrypt page is active; not restarting recovery"
elif ! grep -q 'Unable to decrypt metadata encryption' /tmp/recovery.log; then
    # No metadata failure was reported. Do not touch a working TEE stack just
    # because /data is not mounted for some other reason.
    log "no metadata decrypt failure reported; not restarting recovery"
else
    retries=$(getprop aera.crypto.retries)
    case "$retries" in
        ''|*[!0-9]*) retries=0 ;;
    esac
    if [ "$retries" -ge 1 ]; then
        # One restart was already attempted. A second failure will not fix
        # itself, and leaving a boot loop on the splash screen is worse than
        # showing the UI without /data.
        log "metadata decryption still failing after retry; not restarting again"
        exit 0
    fi
    setprop aera.crypto.retries $((retries + 1))

    log "/data is not mounted; retrying KeyMint with a fresh QSEECom handle"

    setprop ctl.stop keystore2
    setprop ctl.stop keymint-qti
    wait_not_running keystore2 50
    wait_not_running keymint-qti 50

    # prepdecrypt replaces the recovery security-patch placeholders before
    # KeyMint may open the TEE. It always sets crypto.ready after qseecomd is
    # up, including on mount failures.
    wait_prop crypto.ready 1 300

    setprop ctl.start keymint-qti
    wait_service keymint-qti running 50
    # Give KeyMint time to register its AIDL services before keystore2 starts.
    # Starting keystore2 in that window makes it take the legacy HIDL path,
    # which rejects the wrapped metadata keyblob (INCOMPATIBLE_BLOCK_MODE).
    sleep 1

    setprop ctl.start keystore2
    if wait_keystore 200; then
        log "keystore2 ready for retry"
    else
        log "keystore2 not ready before retry"
    fi

    # Do NOT fall through to wlan-bootstrap below: it mounts the vendor
    # partitions, and a restarted TWRP then finds keymaster 4.x declared in
    # /vendor/etc/vintf/manifest.xml, switches its metadata decryption to that
    # (unused) HAL and fails with "Unable to decrypt metadata encryption" for
    # the rest of the boot.
    setprop ctl.restart recovery
    exit 0
fi

# gatekeeperd chdir()s into /data/misc/gatekeeper and exits if it is missing,
# which it is until /data is mounted. Wait for /data, create it, then (re)start
# gatekeeperd.
i=0
while ! grep -q ' /data ' /proc/mounts && [ "$i" -lt 300 ]; do
    sleep 0.2
    i=$((i + 1))
done
mkdir -p /data/misc/gatekeeper
chown system:system /data/misc/gatekeeper
setprop ctl.restart gatekeeperd

# WLAN is brought up only after /data is mounted: bringing the QCA6490 up
# before the metadata key upgrade makes the upgrade fail, and mounting the
# vendor partitions before TWRP has decrypted changes which Keymaster path TWRP
# picks. wlan-start.sh mounts them only long enough to copy the config and load
# the modules, then unmounts them again.
if grep -q ' /data ' /proc/mounts; then
    setprop ctl.start wlan-bootstrap
else
    log "/data not mounted; leaving vendor partitions unmounted so TWRP keeps the AIDL KeyMint path"
fi
