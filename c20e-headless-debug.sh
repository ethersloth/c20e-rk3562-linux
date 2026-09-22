#!/bin/bash
set -euo pipefail

ROOT="${1:-/mnt}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo/root." >&2
    exit 1
fi

if [ ! -d "$ROOT/etc/systemd/system" ]; then
    echo "ERROR: $ROOT does not look like the mounted C20e Debian rootfs." >&2
    exit 1
fi

echo "Configuring C20e for headless diagnostic boot at $ROOT"

# Keep the USB recovery path enabled.
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true

# Keep the old polling USB role manager disabled.
systemctl --root="$ROOT" disable usb-role-manager.service >/dev/null 2>&1 || true

# Prevent the graphical stack from starting during this diagnostic boot.
systemctl --root="$ROOT" disable lightdm.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" set-default multi-user.target >/dev/null

echo
echo "C20e headless diagnostic mode configured."
echo "default target: $(systemctl --root="$ROOT" get-default)"
echo "c20e-usb-debug: $(systemctl --root="$ROOT" is-enabled c20e-usb-debug.service 2>/dev/null || true)"
echo "ttyGS0 getty: $(systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service 2>/dev/null || true)"
echo "usb-role-manager: $(systemctl --root="$ROOT" is-enabled usb-role-manager.service 2>/dev/null || true)"
echo "lightdm: $(systemctl --root="$ROOT" is-enabled lightdm.service 2>/dev/null || true)"
echo
echo "No kernel, DTB, bootloader, Wi-Fi, camera, or internal eMMC changes were made."
