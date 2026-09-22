#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${1:-}"; REPO="${RKDEBIAN_REPO:-/home/${SUDO_USER:-$USER}/Desktop/workspace/rk3562deb}"; IMAGE="$REPO/src/kernel/arch/arm64/boot/Image"; MNT="/mnt/c20e-deploy"
# Which board DTB becomes /boot/rk3562.dtb. Must match the --gpu-stack the
# kernel was built with: "mali" uses the BSP Bifrost driver + libmali
# userspace, "panfrost" uses Mesa. Deploying the wrong one gives a GPU the
# installed userspace cannot drive.
GPU_STACK="${RKDEBIAN_GPU_STACK:-${2:-panfrost}}"
case "$GPU_STACK" in
    mali)     DTB="$REPO/src/kernel/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10.dtb" ;;
    panfrost) DTB="$REPO/src/kernel/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb" ;;
    *) echo "ERROR: unsupported GPU stack '$GPU_STACK' (expected mali or panfrost)" >&2; exit 1 ;;
esac
# Keep at most this many previous Image/DTB backups on the 256MB boot
# partition. Each Image backup is ~40MB, so without pruning the partition
# fills and the deploy fails mid-way (it fails safely, during the backup,
# before overwriting anything -- but it still blocks the deploy).
KEEP_BACKUPS="${C20E_KEEP_BACKUPS:-1}"
die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ sync || true; mountpoint -q "$MNT/boot" && umount "$MNT/boot" || true; mountpoint -q "$MNT" && umount "$MNT" || true; rmdir "$MNT/boot" "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DEV" ]] || die "Usage: sudo $0 /dev/sdX"
[[ "$DEV" == /dev/sd? ]] || die "Refusing non-/dev/sdX target: $DEV"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
[[ -b "${DEV}1" && -b "${DEV}2" && -b "${DEV}3" && -b "${DEV}4" ]] || die "Expected four partitions."
[[ "$(lsblk -dnro FSTYPE "${DEV}3")" == "vfat" ]] || die "${DEV}3 is not vfat."
[[ "$(lsblk -dnro FSTYPE "${DEV}4")" == "ext4" ]] || die "${DEV}4 is not ext4."
[[ "$(lsblk -dnro LABEL "${DEV}4")" == "rootfs" ]] || die "${DEV}4 is not labeled rootfs."
[[ -f "$IMAGE" ]] || die "Kernel missing: $IMAGE"
[[ -f "$DTB" ]] || die "DTB missing: $DTB"
lsblk -nrpo MOUNTPOINTS "$DEV" | grep -q '/' && die "A partition is already mounted."
echo "C20e target:"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN "$DEV"
echo "GPU stack:     $GPU_STACK"
echo "DTB source:    $(basename "$DTB")"
echo "Kernel SHA256: $(sha256sum "$IMAGE" | awk '{print $1}')"; echo "DTB SHA256: $(sha256sum "$DTB" | awk '{print $1}')"
read -r -p "Type C20E to deploy to $DEV: " CONFIRM; [[ "$CONFIRM" == "C20E" ]] || die "Cancelled."
mkdir -p "$MNT"; mount "${DEV}4" "$MNT"; mkdir -p "$MNT/boot"; mount "${DEV}3" "$MNT/boot"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Prune oldest backups first so the new one always has room.
prune(){
    local pattern="$1" keep="$2" f
    # shellcheck disable=SC2012
    ls -1t "$MNT/boot/"$pattern 2>/dev/null | tail -n +$((keep+1)) | while read -r f; do
        echo "  pruning old backup: $(basename "$f")"; rm -f "$f"
    done
}
echo "Pruning old backups (keeping newest $KEEP_BACKUPS):"
prune 'Image.before-c20e-deploy-*'      "$KEEP_BACKUPS"
prune 'rk3562.dtb.before-c20e-deploy-*' "$KEEP_BACKUPS"
df -h "$MNT/boot" | tail -1
[[ -f "$MNT/boot/Image" ]] && cp -a "$MNT/boot/Image" "$MNT/boot/Image.before-c20e-deploy-$STAMP"
[[ -f "$MNT/boot/rk3562.dtb" ]] && cp -a "$MNT/boot/rk3562.dtb" "$MNT/boot/rk3562.dtb.before-c20e-deploy-$STAMP"
install -m 0644 "$IMAGE" "$MNT/boot/Image"; install -m 0644 "$DTB" "$MNT/boot/rk3562.dtb"; sync
cmp -s "$IMAGE" "$MNT/boot/Image" || die "Kernel verification FAILED."
cmp -s "$DTB" "$MNT/boot/rk3562.dtb" || die "DTB verification FAILED."
echo "Installed and verified:"; sha256sum "$MNT/boot/Image" "$MNT/boot/rk3562.dtb"
echo "Factory bootchain ${DEV}1/${DEV}2 was NOT modified."; echo "SUCCESS - unmounting."
