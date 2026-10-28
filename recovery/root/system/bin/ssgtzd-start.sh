#!/system/bin/sh
# Start QTI's Secure Services Gateway daemon as early as possible.
#
# The working AERA/OrangeFox trees start vendor.ssgtzd together with keymint and
# the gatekeeper HAL, and the TEE-backed credential path on SPU platforms
# expects it. In recovery /vendor is a tmpfs until TWRP mounts the real vendor
# logical partition, so the binary only appears part-way through startup: wait
# for it, start the daemon, and only then let the gatekeeper HAL start.
LOG=/tmp/ssgtzd-start.log
: > "$LOG"
log() { echo "ssgtzd-start: $*" >> "$LOG"; }

mkdir -p /data/vendor/qwes
chown system:system /data/vendor/qwes 2>/dev/null

# Opportunistic and bounded: recovery no longer keeps /vendor mounted, so the
# binary may never appear. Thirty seconds is long enough for TWRP's startup
# vendor mount without delaying the rest of the early boot.
i=0
while [ ! -x /vendor/bin/ssgtzd ] && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
done
if [ ! -x /vendor/bin/ssgtzd ]; then
    log "/vendor/bin/ssgtzd never appeared"
    exit 0
fi
log "ssgtzd found after $i ticks; starting"

setprop ctl.start ssgtzd
i=0
while [ ! -S /dev/socket/ssgtzd ] && [ "$i" -lt 150 ]; do
    sleep 0.1
    i=$((i + 1))
done
log "ssgtzd socket: $([ -S /dev/socket/ssgtzd ] && echo up || echo missing)"

# KeyMint must have registered before the gatekeeper HAL may start.
i=0
while [ "$(getprop vendor.sys.listeners.registered)" != "true" ] && [ "$i" -lt 300 ]; do
    sleep 0.2
    i=$((i + 1))
done

log "listeners.registered=$(getprop vendor.sys.listeners.registered)"
setprop aera.ssgtzd.ready 1
# The gatekeeper HAL must NOT wait for this script: TWRP mounts /vendor after
# its startup decrypt, so gating the HAL on ssgtzd deadlocks the UI. ssgtzd is
# opportunistic - it starts as soon as /vendor appears.
