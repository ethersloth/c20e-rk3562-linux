#!/bin/bash
# Bring up Bluetooth on the C20e.
#
# Ordering is the whole problem. skwbt's probe immediately issues HCI Read
# Local Version, and the Seekwave chip does not answer HCI until its BT
# firmware service has been started:
#
#   btseekwave_send_hci_command cp response timeout, ret:0
#   btseekwave_download_nv, read local version err
#
# so hci_register_dev() is never reached and no hci0 appears. Worse, once
# that failed probe has claimed the BT port, writing to
# /proc/skwsdio/bt_service BLOCKS -- which, in a oneshot ordered
# Before=bluetooth.service, hangs the boot and takes org.bluez, power
# profiles and parts of the Phosh session down with it.
#
# So: make sure skwbt is NOT loaded, start the chip side, then load skwbt so
# its probe runs against an awake chip. /etc/modules-load.d must not
# auto-load skwbt or the early probe happens before this script can run.
#
# Every step is bounded and this script always exits 0. Bluetooth failing is
# an inconvenience; hanging the boot is not acceptable.
set -u
LOG=/var/log/c20e-bt-bringup.log
exec >>"$LOG" 2>&1
echo "=== c20e bt bringup $(date -Is) ==="

PROC=/proc/skwsdio/bt_service
[ -e "$PROC" ] || { echo "no $PROC -- is skw_sdio_lite loaded?"; exit 0; }

# Drop any early probe that already claimed the port, or the write below hangs.
if lsmod | grep -q '^skwbt'; then
    echo "skwbt was already loaded (early probe); removing it first"
    timeout 10 modprobe -r skwbt || echo "  rmmod skwbt failed/timed out"
    sleep 0.5
fi

echo "bt_service before: $(cat "$PROC" 2>/dev/null)"
# Bounded: this is the call that hung the boot.
if timeout 15 sh -c "echo start > $PROC"; then
    echo "start written"
else
    echo "writing start FAILED or timed out; giving up (boot continues)"
    exit 0
fi

for _ in $(seq 1 20); do
    [ "$(cat "$PROC" 2>/dev/null)" = "START" ] && break
    sleep 0.25
done
echo "bt_service after:  $(cat "$PROC" 2>/dev/null)"

timeout 20 modprobe skwbt || { echo "modprobe skwbt failed/timed out"; exit 0; }

for _ in $(seq 1 20); do
    [ -n "$(ls /sys/class/bluetooth/ 2>/dev/null)" ] && break
    sleep 0.25
done
echo "hci devices: $(ls /sys/class/bluetooth/ 2>/dev/null | tr '\n' ' ')"
exit 0
