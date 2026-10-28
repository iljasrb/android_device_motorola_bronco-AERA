#!/system/bin/sh
# Bounded safety net for MTP over FunctionFS.
#
# TWRP switches sys.usb.config to "mtp,adb" before its MTP server has written
# the MTP descriptors, and the kernel refuses to bind an ffs function without
# them. If the server never publishes sys.usb.ffs.mtp.ready the gadget would stay
# unbound - no adb, no MTP, nothing on the bus. Fall back to plain adb so the
# device keeps a working USB transport.
LOG=/tmp/mtp-fallback.log
i=0
while [ "$i" -lt 40 ]; do
    [ "$(getprop sys.usb.ffs.mtp.ready)" = "1" ] && exit 0
    [ "$(getprop sys.usb.config)" != "mtp,adb" ] && exit 0
    sleep 0.5
    i=$((i + 1))
done
echo "mtp never became ready; falling back to adb" >> "$LOG"
setprop sys.usb.config adb
