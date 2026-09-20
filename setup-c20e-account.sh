#!/usr/bin/env bash
# Run the C20e first-boot account wizard offline, from the laptop.
#
# Normally c20e-firstboot.service runs the wizard on the tablet over the USB
# serial gadget. That needs a host on the other end of the USB-C cable; if the
# PHY reports USB_DCP_CHARGER (a charger or a charge-only cable) the gadget
# binds fine but nothing ever attaches, and the service sits blocked on
# "Username:" forever. This script performs the same setup with the card in a
# reader instead, so account creation is never gated on the serial console.
#
# It does NOT reimplement the wizard. It extracts the real
# /usr/local/sbin/c20e-firstboot from the card and runs it under
# qemu-aarch64-static in a chroot, with only the trailing reboot removed. One
# source of truth, so the two paths cannot drift apart.
#
# Your password is typed into the target's own passwd(1) inside the chroot.
# It is never passed on a command line and never written to shell history.
#
# Usage: sudo ./setup-c20e-account.sh [/dev/sdX]
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
MNT="$(mktemp -d)"
QEMU=/usr/bin/qemu-aarch64-static

die(){ echo "ERROR: $*" >&2; exit 1; }

cleanup(){
    # Reverse order, and never fail the script while tearing down.
    for m in dev/pts dev proc sys; do
        mountpoint -q "$MNT/$m" && umount -l "$MNT/$m" || true
    done
    mountpoint -q "$MNT" && umount "$MNT" || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}4" ]] || die "no ${DEV}4 -- is the card in and is $DEV right?"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
[[ -x "$QEMU" ]] || die "missing $QEMU (dnf install qemu-user-static-aarch64)"

echo "[*] mounting ${DEV}4"
mount "${DEV}4" "$MNT" || die "could not mount ${DEV}4"

WIZ="$MNT/usr/local/sbin/c20e-firstboot"
[[ -f "$WIZ" ]] || die "${DEV}4 has no c20e-firstboot -- wrong card or wrong partition?"

if [[ -e "$MNT/var/lib/c20e/firstboot-complete" ]]; then
    echo "[=] This card already has an account:"
    echo "      $(cat "$MNT/var/lib/c20e/primary-user" 2>/dev/null || echo '(unknown)')"
    die "refusing to run again; delete var/lib/c20e/firstboot-complete to force."
fi

echo "[*] staging qemu-aarch64-static"
cp "$QEMU" "$MNT/usr/bin/" || die "could not stage qemu"

# /run is deliberately NOT bind-mounted. The wizard ends in `systemctl reboot`,
# and exposing the host's systemd socket to the chroot would reboot THIS laptop.
# We strip that line below as well, but not mounting /run makes it impossible.
for m in proc sys dev dev/pts; do
    mkdir -p "$MNT/$m"
    case "$m" in
        proc) mount -t proc proc "$MNT/proc" ;;
        sys)  mount -t sysfs sys "$MNT/sys" ;;
        *)    mount --bind "/$m" "$MNT/$m" ;;
    esac
done

# Strip only the reboot tail. Everything above it -- user creation, password,
# groups, home migration from the chaos placeholder, hostname, lightdm
# autologin, service repointing, the firstboot-complete marker and the
# serial-getty handback -- runs exactly as it does on the tablet.
sed -e '/^systemctl reboot$/d' \
    -e '/^sleep 3$/d' \
    -e 's#^echo "Rebooting into the desktop\.\.\."$#echo "Card is ready. Put it back in the tablet and power on."#' \
    "$WIZ" > "$MNT/usr/local/sbin/c20e-firstboot-offline"
chmod 0755 "$MNT/usr/local/sbin/c20e-firstboot-offline"

grep -q '^systemctl reboot$' "$MNT/usr/local/sbin/c20e-firstboot-offline" \
    && die "internal error: reboot line survived the strip; refusing to continue"

echo
echo "============================================================"
echo " Running the C20e setup wizard against the card"
echo "============================================================"
echo
chroot "$MNT" /usr/local/sbin/c20e-firstboot-offline || die "the wizard did not complete"

rm -f "$MNT/usr/local/sbin/c20e-firstboot-offline"

# systemctl works for enable/disable/mask/unmask/set-default in a chroot, but
# it can bail out with "System has not been booted with systemd". Those calls
# are all `|| true` in the wizard, so verify the end state rather than trust it.
echo
echo "[*] verifying the systemd handback"
E="$MNT/etc/systemd/system"

if [[ -L "$E/serial-getty@ttyGS0.service" ]] \
   && [[ "$(readlink "$E/serial-getty@ttyGS0.service")" == "/dev/null" ]]; then
    rm -f "$E/serial-getty@ttyGS0.service"
    echo "[+] unmasked serial-getty@ttyGS0 (wizard's systemctl could not)"
fi
mkdir -p "$E/getty.target.wants"
if [[ ! -e "$E/getty.target.wants/serial-getty@ttyGS0.service" ]]; then
    ln -sf /lib/systemd/system/serial-getty@.service \
           "$E/getty.target.wants/serial-getty@ttyGS0.service"
    echo "[+] enabled serial-getty@ttyGS0"
fi

rm -f "$E/multi-user.target.wants/c20e-firstboot.service"

if [[ -e "$MNT/lib/systemd/system/graphical.target" ]]; then
    ln -sf /lib/systemd/system/graphical.target "$E/default.target"
    echo "[+] default.target -> graphical.target"
fi
if [[ -e "$MNT/lib/systemd/system/lightdm.service" ]] \
   && [[ ! -e "$E/display-manager.service" ]]; then
    ln -sf /lib/systemd/system/lightdm.service "$E/display-manager.service"
    echo "[+] enabled lightdm"
fi

[[ -e "$MNT/var/lib/c20e/firstboot-complete" ]] || die "firstboot-complete marker was not written"
U="$(cat "$MNT/var/lib/c20e/primary-user" 2>/dev/null || echo '?')"

sync
echo
echo "[*] result:"
echo "    user:            $U"
echo "    hostname:        $(cat "$MNT/etc/hostname" 2>/dev/null || echo '?')"
echo "    default.target:  $(readlink "$E/default.target" 2>/dev/null || echo '(unset)')"
echo "    ttyGS0 getty:    $([[ -e "$E/getty.target.wants/serial-getty@ttyGS0.service" ]] && echo enabled || echo MISSING)"
echo "    chaos locked:    $(grep -q '^chaos:!' "$MNT/etc/shadow" && echo yes || echo NO)"
echo
echo "SUCCESS - put the card in the tablet and power on."
echo "The wizard will not run again; log in as '$U'."
