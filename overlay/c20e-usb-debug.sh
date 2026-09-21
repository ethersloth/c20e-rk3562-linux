#!/bin/bash
set -eu

LOG=/var/log/c20e-usb-debug.log
exec >>"$LOG" 2>&1
echo "=== C20e USB debug startup $(date -Is) ==="

mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config

if [ -w /sys/devices/platform/ff740000.usb2-phy/otg_mode ]; then
    echo peripheral > /sys/devices/platform/ff740000.usb2-phy/otg_mode
fi
if [ -w /sys/kernel/debug/usb/fe500000.usb/mode ]; then
    echo device > /sys/kernel/debug/usb/fe500000.usb/mode
fi

G=/sys/kernel/config/usb_gadget/c20e
if [ -d "$G" ] && [ -e "$G/UDC" ]; then
    printf '' > "$G/UDC" 2>/dev/null || true
fi

mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"

mkdir -p "$G/strings/0x409"
echo C20EDEBUG001 > "$G/strings/0x409/serialnumber"
echo Aiprotablet > "$G/strings/0x409/manufacturer"
echo "C20e USB Debug Console" > "$G/strings/0x409/product"

mkdir -p "$G/configs/c.1/strings/0x409"
echo "C20e Debug ACM" > "$G/configs/c.1/strings/0x409/configuration"

mkdir -p "$G/functions/acm.usb0"
ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0" 2>/dev/null || true

UDC=""
for i in $(seq 1 50); do
    UDC="$(ls /sys/class/udc 2>/dev/null | head -n1 || true)"
    [ -n "$UDC" ] && break
    sleep 0.1
done
if [ -z "$UDC" ]; then
    echo "ERROR: no USB Device Controller found in /sys/class/udc"
    exit 1
fi

echo "$UDC" > "$G/UDC"
echo "Bound C20e debug gadget to UDC: $UDC"
[ -e /dev/ttyGS0 ] && echo "ttyGS0 is available" || \
    echo "WARNING: /dev/ttyGS0 not present immediately after UDC bind"
