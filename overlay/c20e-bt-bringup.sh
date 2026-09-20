#!/bin/bash
# Bring up Bluetooth on the C20e.
#
# Two things have to happen in the right order, and the driver cannot do it
# alone:
#
#  1. The BT firmware service must be started on the Seekwave chip. Until it
#     is, the chip does not answer HCI commands at all.
#  2. skwbt's platform driver must probe AFTER that. Its probe immediately
#     calls btseekwave_download_nv(), which issues HCI Read Local Version; if
#     the service is not running that times out:
#
#       btseekwave_send_hci_command cp response timeout, ret:0
#       btseekwave_download_nv, read local version err
#
#     and hci_register_dev() is never reached, so no hci0 appears.
#
# At boot the platform device is created during skw_sdio probe, long before
# anything in userspace can start the service, so the probe always loses the
# race. Starting the service and then reloading skwbt re-runs probe with the
# chip awake.
#
# Reloading skwbt is safe for networking: it is an independent module with no
# users, and Wi-Fi lives in skw/skw_sdio_lite which are left alone.
set -u
LOG=/var/log/c20e-bt-bringup.log
exec >>"$LOG" 2>&1
echo "=== c20e bt bringup $(date -Is) ==="

PROC=/proc/skwsdio/bt_service
[ -w "$PROC" ] || { echo "no $PROC -- is skw_sdio_lite loaded?"; exit 0; }

echo "bt_service before: $(cat "$PROC" 2>/dev/null)"
echo start > "$PROC" || { echo "failed to start bt service"; exit 1; }

# Wait for the chip to report BTREADY rather than sleeping a fixed time.
for i in $(seq 1 20); do
    [ "$(cat "$PROC" 2>/dev/null)" = "START" ] && break
    sleep 0.25
done
echo "bt_service after:  $(cat "$PROC" 2>/dev/null)"

modprobe -r skwbt 2>/dev/null
sleep 0.5
modprobe skwbt || { echo "modprobe skwbt failed"; exit 1; }

for i in $(seq 1 20); do
    [ -n "$(ls /sys/class/bluetooth/ 2>/dev/null)" ] && break
    sleep 0.25
done
echo "hci devices: $(ls /sys/class/bluetooth/ 2>/dev/null | tr '\n' ' ')"
exit 0
