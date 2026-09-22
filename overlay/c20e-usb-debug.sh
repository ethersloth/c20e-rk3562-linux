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

# USB Ethernet (RNDIS) beside the console, like the FlexEdge: the tablet is
# 192.168.241.241 and hands the host a DHCP address in 192.168.241.0/24 (see
# the c20e-usb0 NetworkManager profile, which uses NM's shared mode). This is
# a wired path to the tablet that survives Wi-Fi being down.
#
# RNDIS rather than ECM because Windows has a driver for it out of the box;
# Linux and macOS handle it too. Fixed MACs so the interface name and the DHCP
# lease stay put; locally administered (02:) range.
if [ -d /sys/class/udc ] && mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
    echo 02:c2:0e:5b:41:20 > "$G/functions/rndis.usb0/dev_addr"   2>/dev/null || true
    echo 02:c2:0e:5b:41:21 > "$G/functions/rndis.usb0/host_addr"  2>/dev/null || true
    ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0" 2>/dev/null || true
    # Windows needs these OS descriptors to bind its RNDIS driver.
    echo 1       > "$G/os_desc/use"           2>/dev/null || true
    echo 0xcd    > "$G/os_desc/b_vendor_code" 2>/dev/null || true
    echo MSFT100 > "$G/os_desc/qw_sign"       2>/dev/null || true
    echo RNDIS   > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"     2>/dev/null || true
    echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id" 2>/dev/null || true
    ln -s "$G/configs/c.1" "$G/os_desc/c.1" 2>/dev/null || true
    echo "RNDIS function added"
else
    echo "WARNING: no rndis gadget function (kernel without CONFIG_USB_CONFIGFS_RNDIS?) -- console only"
fi

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
ip link show usb0 >/dev/null 2>&1 && echo "usb0 (RNDIS) is available" || \
    echo "note: no usb0 interface (RNDIS not bound)"
