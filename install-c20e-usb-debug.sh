#!/bin/bash
set -euo pipefail

ROOT="${1:-/mnt}"
DEBUG_SCRIPT="$ROOT/usr/local/sbin/c20e-usb-debug"
SERVICE="$ROOT/etc/systemd/system/c20e-usb-debug.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this installer with sudo/root." >&2
    exit 1
fi

if [ ! -d "$ROOT/etc/systemd" ] || [ ! -d "$ROOT/usr" ]; then
    echo "ERROR: $ROOT does not look like a mounted Debian root filesystem." >&2
    exit 1
fi

install -d "$ROOT/usr/local/sbin" "$ROOT/etc/systemd/system"

cat > "$DEBUG_SCRIPT" <<'EOF'
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

# Cleanly unbind an existing instance before rebuilding it.
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

if [ -e /dev/ttyGS0 ]; then
    echo "ttyGS0 is available"
else
    echo "WARNING: /dev/ttyGS0 was not present immediately after UDC bind"
fi
EOF

chmod 0755 "$DEBUG_SCRIPT"

cat > "$SERVICE" <<'EOF'
[Unit]
Description=C20e USB CDC ACM debug console
After=systemd-modules-load.service local-fs.target
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-usb-debug
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Disable the old polling role manager. It caused repeated DWC3 host/device cycling.
systemctl --root="$ROOT" disable usb-role-manager.service >/dev/null 2>&1 || true

# Enable the recovery gadget.
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null

# Keep the serial getty explicitly enabled as a fallback as well.
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true

echo
echo "C20e USB recovery console installed into: $ROOT"
echo "  script : /usr/local/sbin/c20e-usb-debug"
echo "  service: /etc/systemd/system/c20e-usb-debug.service"
echo
echo "usb-role-manager.service:"
systemctl --root="$ROOT" is-enabled usb-role-manager.service 2>/dev/null || true
echo
echo "c20e-usb-debug.service:"
systemctl --root="$ROOT" is-enabled c20e-usb-debug.service 2>/dev/null || true
echo
echo "serial-getty@ttyGS0.service:"
systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service 2>/dev/null || true
