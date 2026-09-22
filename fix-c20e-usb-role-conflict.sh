#!/usr/bin/env bash
# Stop usb-role-manager from fighting the USB debug console on an existing card.
#
# Symptom this fixes: the tablet boots fine, but the screen scrolls xhci
# register/deregister messages forever and /dev/ttyACM0 on the host keeps
# appearing and vanishing, so the first-boot wizard can never be reached.
#
# Cause: usb-role-manager.service runs usb-mode-switch.sh in "auto" mode, which
# calls set_mode host unconditionally at startup -- tearing down the gadget that
# c20e-usb-debug.service just bound. Its poll loop then oscillates host <->
# peripheral, because the port is reset so often that enumeration never
# completes, so the battery never reports "Charging" and the loop never settles.
#
# The board also has hardware role switching now (HUSB320 usb-c-connector wired
# to usbdrd_dwc3 via usb-role-switch in the board DTS), which makes this
# userspace poller redundant as well as harmful.
#
# Fix applied in the repo: build_rootfs.sh defaults the service to disabled, and
# c20e-usb-debug.service declares Conflicts=usb-role-manager.service so the
# debug console always wins. This script applies the same result to a card that
# was already flashed.
#
# Usage: sudo ./fix-c20e-usb-role-conflict.sh [/dev/sdX]
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
MNT="$(mktemp -d)"

die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}4" ]] || die "no ${DEV}4 -- is the card in and is $DEV right?"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."

echo "[*] mounting ${DEV}4 read-write"
mount "${DEV}4" "$MNT" || die "could not mount ${DEV}4"
[[ -d "$MNT/etc/systemd/system" ]] || die "${DEV}4 does not look like the rootfs"

# Disable by removing the enablement symlink directly. Doing this with
# `chroot ... systemctl` would need an aarch64 interpreter on the host, and
# `systemctl --root=` is not available on every host distro either.
WANTS="$MNT/etc/systemd/system/multi-user.target.wants/usb-role-manager.service"
if [[ -L "$WANTS" || -e "$WANTS" ]]; then
    rm -f "$WANTS"
    echo "[+] removed $(basename "$WANTS") from multi-user.target.wants"
else
    echo "[=] usb-role-manager was already not enabled"
fi

# Mask it too, so nothing can pull it back in as a dependency. A merely
# disabled unit can still be started by another unit's Wants=/Requires= --
# this is the same trap that made serial-getty@ttyGS0 appear before the
# first-boot wizard.
ln -sf /dev/null "$MNT/etc/systemd/system/usb-role-manager.service"
echo "[+] masked usb-role-manager.service"

# Belt and braces: teach the on-card debug unit to win outright, so the fix
# survives someone re-enabling the role manager later.
UNIT="$MNT/etc/systemd/system/c20e-usb-debug.service"
if [[ -f "$UNIT" ]] && ! grep -q '^Conflicts=usb-role-manager.service' "$UNIT"; then
    sed -i '/^\[Unit\]/a Conflicts=usb-role-manager.service' "$UNIT"
    echo "[+] added Conflicts=usb-role-manager.service to c20e-usb-debug.service"
fi

sync
echo
echo "[*] resulting state:"
echo "    usb-role-manager.service -> $(readlink "$MNT/etc/systemd/system/usb-role-manager.service" 2>/dev/null || echo '(not masked)')"
grep -c . "$UNIT" >/dev/null 2>&1 && { echo "    c20e-usb-debug.service [Unit] section:"; sed -n '/^\[Unit\]/,/^\[Service\]/p' "$UNIT" | sed 's/^/      /'; }

umount "$MNT"
echo
echo "SUCCESS - put the card in the tablet. The xhci cycling should stop and"
echo "the first-boot wizard should appear on /dev/ttyACM0 with no login prompt."
