#!/usr/bin/env bash
# Install the staged V5.9r2 hybrid Seekwave Wi-Fi modules onto the C20e SD card.
# Run rebuild-c20e-hybrid-seekwave.sh first; this only copies what it staged.
#
# Usage: sudo ./install-c20e-hybrid-seekwave.sh /dev/sdX
set -Eeuo pipefail

DEV="${1:-}"
REPO="${RKDEBIAN_REPO:-/home/${SUDO_USER:-$USER}/Desktop/workspace/rk3562deb}"
STAGE="$REPO/out/c20e-seekwave"
KERNEL="$REPO/src/kernel"
MNT="/mnt/c20e-seekwave-install"

die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ sync || true; mountpoint -q "$MNT" && umount "$MNT" || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DEV" ]] || die "Usage: sudo $0 /dev/sdX"
[[ "$DEV" == /dev/sd? ]] || die "Refusing non-/dev/sdX target: $DEV"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
[[ -b "${DEV}4" ]] || die "Expected rootfs partition ${DEV}4."
[[ "$(lsblk -dnro FSTYPE "${DEV}4")" == "ext4" ]] || die "${DEV}4 is not ext4."
[[ "$(lsblk -dnro LABEL "${DEV}4")" == "rootfs" ]] || die "${DEV}4 is not labeled rootfs."
lsblk -nrpo MOUNTPOINTS "$DEV" | grep -q '/' && die "A partition is already mounted."

[[ -f "$STAGE/skw_sdio_lite.ko" ]] || die "missing $STAGE/skw_sdio_lite.ko (run rebuild-c20e-hybrid-seekwave.sh)"
[[ -f "$STAGE/skw.ko" ]]           || die "missing $STAGE/skw.ko (run rebuild-c20e-hybrid-seekwave.sh)"

KREL="$(make -s -C "$KERNEL" ARCH=arm64 kernelrelease)"
echo "Kernel release: $KREL"
for ko in "$STAGE/skw_sdio_lite.ko" "$STAGE/skw.ko"; do
    vm="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
    [[ "$vm" == "$KREL" ]] || die "$(basename "$ko") vermagic '$vm' != '$KREL'"
done
sha256sum "$STAGE"/*.ko

read -r -p "Type C20E to install hybrid Seekwave modules to $DEV: " CONFIRM
[[ "$CONFIRM" == "C20E" ]] || die "Cancelled."

mkdir -p "$MNT"; mount "${DEV}4" "$MNT"
[[ -f "$MNT/etc/os-release" ]] || die "target does not look like a Linux rootfs"
[[ -d "$MNT/lib/modules/$KREL" ]] || die "target lacks /lib/modules/$KREL"

DEST="$MNT/lib/modules/$KREL/updates/c20e-seekwave"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -d "$DEST" ]]; then
    echo "Backing up existing modules to ${DEST}.before-$STAMP"
    cp -a "$DEST" "${DEST}.before-$STAMP"
fi
install -D -m 0644 "$STAGE/skw_sdio_lite.ko" "$DEST/skw_sdio_lite.ko"
install -D -m 0644 "$STAGE/skw.ko"           "$DEST/skw.ko"

# Load order matters: the SDIO layer must come up before the Wi-Fi upper,
# which imports its symbols.
[[ -f "$MNT/etc/modules-load.d/c20e-seekwave.conf" ]] && \
    cp -a "$MNT/etc/modules-load.d/c20e-seekwave.conf" "$MNT/etc/modules-load.d/c20e-seekwave.conf.before-$STAMP"
printf 'skw_sdio_lite\nskw\n' > "$MNT/etc/modules-load.d/c20e-seekwave.conf"

depmod -b "$MNT" "$KREL"
sync

echo "Installed:"
ls -la "$DEST"
echo "modules-load.d:"; cat "$MNT/etc/modules-load.d/c20e-seekwave.conf"
echo "SUCCESS - unmounting."
