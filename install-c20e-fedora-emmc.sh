#!/usr/bin/env bash
# Install Fedora KDE Plasma Mobile onto the C20e's INTERNAL eMMC.
# Runs ON THE TABLET with sudo, booted from the Debian SD card.
#
# THIS ERASES ANDROID. Restore image: emmc_image_backup/ on the laptop
# (c20e-emmc-preinstall.img.zst + c20e-emmc-gpt.sfdisk).
#
# Why this is recoverable if it goes wrong: the RK3562 BootROM checks the SD
# card BEFORE the eMMC. Proven the hard way -- a card with a bad bootloader
# made the tablet completely dead, Android included, until it was removed. So
# with the Debian SD card inserted the tablet always boots Debian, whatever is
# on the eMMC. To boot Fedora, remove the card. If Fedora fails, put it back.
#
# Layout written (mirrors the SD card layout, which is known to boot):
#   sector 64      idbloader   (upstream bootloader, as on the SD card)
#   sector 16384   u-boot.itb
#   p3  boot       vfat 256 MiB   Image, rk3562.dtb, extlinux/extlinux.conf
#   p4  rootfs     btrfs, rest of the eMMC, Fedora (grown on first boot by
#                  x-systemd.growfs from Fedora's own fstab)
#
# Usage: sudo ./install-c20e-fedora-emmc.sh [--dry-run] [SRC_DIR]
#        SRC_DIR default /var/tmp/c20e-fedora
set -Eeuo pipefail

DRY=0; SRC=/var/tmp/c20e-fedora
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) SRC="$a" ;; esac; done

EMMC=/dev/mmcblk2
IDB_SECTOR=64; UB_SECTOR=16384; BOOT_START=32768; BOOT_SIZE=524288; ROOT_START=557056

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[fedora-emmc] $*"; }
run(){ if [[ $DRY -eq 1 ]]; then echo "  DRY-RUN: $*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] || die "run with sudo"

# ---------------------------------------------------------------- interlocks
[[ -b "$EMMC" ]] || die "no $EMMC"
ROOTDEV="$(findmnt -no SOURCE /)"
case "$ROOTDEV" in
    /dev/mmcblk2*) die "the running system is ON the eMMC ($ROOTDEV) -- boot from the SD card first" ;;
    /dev/mmcblk0*) say "running from SD card ($ROOTDEV) -- good" ;;
    *) die "unexpected root device $ROOTDEV; refusing" ;;
esac
SZ=$(( $(cat /sys/block/mmcblk2/size) * 512 / 1024/1024/1024 ))
[[ $SZ -ge 50 && $SZ -le 70 ]] || die "$EMMC is ${SZ} GiB, not the expected ~58 GiB eMMC; refusing"
[[ -e /sys/block/mmcblk2/device/type ]] && [[ "$(cat /sys/block/mmcblk2/device/type)" == "MMC" ]] \
    || die "$EMMC is not reported as an MMC (eMMC) device; refusing"
if findmnt -rno SOURCE | grep -q '^/dev/mmcblk2'; then die "a partition of $EMMC is mounted; refusing"; fi
say "target: $EMMC (${SZ} GiB internal eMMC)"

# ---------------------------------------------------------------- inputs
for f in upstream-idbloader.img upstream-u-boot.itb fedora-root.btrfs.zst manifest \
         boot/Image boot/rk3562.dtb boot/extlinux/extlinux.conf; do
    [[ -f "$SRC/$f" ]] || die "missing $SRC/$f"
done
# shellcheck disable=SC1091
. "$SRC/manifest"
[[ -n "${FEDORA_ROOT_PARTUUID:-}" && -n "${ROOT_SECTORS:-}" && -n "${ROOT_SHA256:-}" ]] \
    || die "manifest incomplete"
grep -q "root=PARTUUID=$FEDORA_ROOT_PARTUUID" "$SRC/boot/extlinux/extlinux.conf" \
    || die "extlinux.conf does not point at PARTUUID $FEDORA_ROOT_PARTUUID"
[[ "$(head -c4 "$SRC/upstream-idbloader.img")" == "LDR " ]] || die "idbloader has wrong magic"
[[ "$(od -An -tx1 -N4 "$SRC/upstream-u-boot.itb" | tr -d ' \n')" == "d00dfeed" ]] || die "u-boot.itb is not a FIT"

say "verifying root image checksum..."
[[ "$(sha256sum "$SRC/fedora-root.btrfs.zst" | cut -d' ' -f1)" == "$ROOT_SHA256" ]] \
    || die "fedora-root.btrfs.zst checksum mismatch -- re-copy it"
say "root image OK ($ROOT_SECTORS sectors, kernel $KERNEL)"

TOTAL=$(cat /sys/block/mmcblk2/size)
ROOT_AVAIL=$(( TOTAL - ROOT_START - 34 ))          # leave room for the backup GPT
[[ $ROOT_AVAIL -gt $ROOT_SECTORS ]] || die "rootfs partition too small"

echo
say "plan:"
echo "    GPT on $EMMC (replaces Android's 25 partitions)"
echo "    idbloader -> sector $IDB_SECTOR, u-boot.itb -> sector $UB_SECTOR"
echo "    p3 boot   vfat  start $BOOT_START size $BOOT_SIZE"
echo "    p4 rootfs btrfs start $ROOT_START size $ROOT_AVAIL  PARTUUID $FEDORA_ROOT_PARTUUID"
echo
if [[ $DRY -eq 0 ]]; then
    echo "  This ERASES Android on the internal eMMC. The restore image is on the laptop."
    read -r -p "  Type ERASE-ANDROID to continue: " ok
    [[ "$ok" == "ERASE-ANDROID" ]] || die "cancelled"
fi

# ---------------------------------------------------------------- write
say "writing GPT..."
run sfdisk --wipe always --wipe-partitions always "$EMMC" <<EOF
label: gpt
first-lba: 34
start=$IDB_SECTOR,  size=1053,   name="idbloader"
start=$UB_SECTOR,   size=8192,   name="uboot"
start=$BOOT_START,  size=$BOOT_SIZE, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="boot", attrs="LegacyBIOSBootable"
start=$ROOT_START,  size=$ROOT_AVAIL, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$FEDORA_ROOT_PARTUUID, name="rootfs"
EOF
run partprobe "$EMMC" 2>/dev/null || run blockdev --rereadpt "$EMMC"
[[ $DRY -eq 1 ]] || sleep 2

say "writing bootloader..."
run dd if="$SRC/upstream-idbloader.img" of="$EMMC" bs=512 seek=$IDB_SECTOR conv=fsync status=none
run dd if="$SRC/upstream-u-boot.itb"    of="$EMMC" bs=512 seek=$UB_SECTOR  conv=fsync status=none

say "creating boot partition..."
run mkfs.vfat -F 32 -n C20EBOOT "${EMMC}p3" >/dev/null
if [[ $DRY -eq 0 ]]; then
    BM="$(mktemp -d)"; mount "${EMMC}p3" "$BM"
    cp -r "$SRC/boot/." "$BM/"; sync; umount "$BM"; rmdir "$BM"
else echo "  DRY-RUN: copy $SRC/boot/* -> ${EMMC}p3"; fi

say "writing Fedora root (${ROOT_SECTORS} sectors)..."
if [[ $DRY -eq 0 ]]; then
    zstd -dc "$SRC/fedora-root.btrfs.zst" \
      | dd of="${EMMC}p4" bs=4M iflag=fullblock oflag=direct status=progress
    sync
else echo "  DRY-RUN: zstd -dc fedora-root.btrfs.zst | dd of=${EMMC}p4"; fi

# ---------------------------------------------------------------- verify
[[ $DRY -eq 1 ]] && { echo; say "DRY RUN complete -- nothing was written."; exit 0; }
say "verifying..."
blockdev --flushbufs "$EMMC" 2>/dev/null || true
t="$(mktemp)"; n=$(( ( $(stat -c%s "$SRC/upstream-idbloader.img") + 511 ) / 512 ))
dd if="$EMMC" of="$t" bs=512 skip=$IDB_SECTOR count=$n status=none
cmp -s -n "$(stat -c%s "$SRC/upstream-idbloader.img")" "$SRC/upstream-idbloader.img" "$t" \
    || die "idbloader read-back mismatch"; rm -f "$t"
[[ "$(blkid -s PARTUUID -o value "${EMMC}p4")" == "$FEDORA_ROOT_PARTUUID" ]] || die "p4 PARTUUID wrong"
[[ "$(blkid -s TYPE -o value "${EMMC}p4")" == "btrfs" ]] || die "p4 is not btrfs"
if grep -qw btrfs /proc/filesystems; then
    VM="$(mktemp -d)"; mount -o ro,subvol=root "${EMMC}p4" "$VM"
    grep -q 'KDE Plasma Mobile' "$VM/etc/os-release" || { umount "$VM"; die "p4 root is not Fedora KDE Mobile"; }
    [[ -d "$VM/lib/modules/$KERNEL" ]] || { umount "$VM"; die "kernel modules missing in Fedora root"; }
    umount "$VM"; rmdir "$VM"
    say "mounted p4: Fedora KDE Mobile root with kernel $KERNEL modules present"
else
    # The Debian kernel on the SD card may predate btrfs support, so it cannot
    # mount p4. Check the btrfs superblock on disk instead: magic "_BHRfS_M"
    # at byte 0x10040, filesystem UUID at 0x10020. That proves Fedora's
    # filesystem landed at the right offset, intact at its start.
    MAGIC=$(dd if="${EMMC}p4" bs=1 skip=$((0x10040)) count=8 status=none)
    [[ "$MAGIC" == "_BHRfS_M" ]] || die "no btrfs superblock on p4"
    FSID=$(dd if="${EMMC}p4" bs=1 skip=$((0x10020)) count=16 status=none | od -An -tx1 | tr -d ' \n')
    say "btrfs superblock present on p4 (fsid $FSID); running kernel has no btrfs, so contents not mounted"
fi

echo
say "SUCCESS. Fedora is on the internal eMMC."
say "To boot it: power off, REMOVE the SD card, power on."
say "To get back to Debian: power off, insert the SD card, power on."
say "USB serial console (/dev/ttyACM0 on the laptop) autologins as root for bring-up."
