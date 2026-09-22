#!/usr/bin/env bash
# Build a bootable C20e Fedora SD card image that can also INSTALL Fedora to
# the tablet's internal eMMC ("Install Fedora to internal storage" in the app
# launcher). Runs on the LAPTOP with sudo; needs out/fedora-emmc/ from
# prepare-c20e-fedora.sh. Writes nothing to any device.
#
# The SD card is the same Fedora as the eMMC bundle, plus the bundle itself
# (under /usr/local/share/c20e-installer) and the launcher.
#
# Two identities are changed on the SD copy, because both systems can be
# attached at once (SD in the slot, Fedora on the eMMC):
#   - btrfs filesystem UUID: btrfs tracks filesystems by it, and two different
#     filesystems with one UUID attached together can be mixed up by the
#     kernel. `btrfstune -m` gives the SD copy a new one instantly; its fstab
#     (which mounts / /home /var BY UUID) is rewritten to match.
#   - root PARTUUID: the SD boot menu names the SD root, the eMMC boot menu the
#     eMMC root, so neither can boot the other's filesystem.
#
# Layout (same offsets as the eMMC install and the Debian SD):
#   sector 64 idbloader, 16384 u-boot.itb, p3 boot vfat 256 MiB (bootable),
#   p4 root btrfs, ROOT_GIB (default 14) -- fits a 16 GB card. The filesystem
#   is grown to the partition on first boot (x-systemd.growfs in Fedora's fstab).
#
# Boot order caveat: the tablet boots the SD card only while the eMMC has no
# bootable bootloader (e.g. still Android). A tablet already running Fedora
# from the eMMC keeps booting the eMMC.
#
# Output: out/fedora-sd/c20e-fedora-sd.img.zst (+ .sha256). The raw image is
# deleted after compressing unless KEEP_RAW=1.
#
# Usage: sudo ./make-c20e-fedora-sd.sh
#   write: zstd -dc out/fedora-sd/c20e-fedora-sd.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
#
# Do NOT write with conv=sparse: it skips zero blocks, leaving the card's old
# contents there -- on a reused Rockchip card that can include stale backup
# bootloader copies the BootROM searches for (the same trap as the eMMC's
# factory idblocks at sectors 2112+).
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$REPO/out/fedora-emmc"
OUT="$REPO/out/fedora-sd"
IMG="$OUT/c20e-fedora-sd.img"
ROOT_GIB="${ROOT_GIB:-14}"
SD_ROOT_PARTUUID="c20ef00d-5d00-4000-8000-000000000004"   # 5d = "SD"; eMMC root is c20ef00d-0000-...
IDB_SECTOR=64; UB_SECTOR=16384; BOOT_START=32768; BOOT_SIZE=524288; ROOT_START=557056
MNT="$(mktemp -d)"; LOOP=""
WORK="$OUT/work"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[fedora-sd] $*"; }
cleanup(){
    mountpoint -q "$MNT" && umount "$MNT" || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run with sudo"
for t in btrfstune sfdisk zstd mcopy losetup; do command -v $t >/dev/null || die "missing tool: $t"; done
for f in manifest fedora-root.btrfs.zst boot/Image boot/rk3562.dtb boot-p3.vfat; do
    [[ -f "$BUNDLE/$f" ]] || die "missing $BUNDLE/$f -- run prepare-c20e-fedora.sh first"
done
for f in upstream-idbloader.img upstream-u-boot.itb; do
    [[ -f "$REPO/bootloader/$f" ]] || die "missing bootloader/$f"
done
# shellcheck disable=SC1091
. "$BUNDLE/manifest"
say "verifying the eMMC bundle checksum..."
[[ "$(sha256sum "$BUNDLE/fedora-root.btrfs.zst" | cut -d' ' -f1)" == "$ROOT_SHA256" ]] || die "bundle root checksum mismatch"

ROOT_SECTORS_SD=$(( ROOT_GIB * 1024 * 1024 * 2 ))
(( ROOT_SECTORS_SD >= ROOT_SECTORS )) || die "ROOT_GIB=$ROOT_GIB is smaller than the filesystem ($ROOT_SECTORS sectors)"
TOTAL=$(( ROOT_START + ROOT_SECTORS_SD + 34 ))    # + backup GPT

rm -rf "$OUT"; mkdir -p "$WORK"

# ---- SD root filesystem: a copy of the bundle's, with its own identity ------
say "decompressing root filesystem copy..."
zstd -d --sparse -q "$BUNDLE/fedora-root.btrfs.zst" -o "$WORK/root.btrfs"
OLD_UUID="$(blkid -s UUID -o value "$WORK/root.btrfs")"
btrfstune -m "$WORK/root.btrfs" >/dev/null
NEW_UUID="$(blkid -s UUID -o value "$WORK/root.btrfs")"
[[ -n "$NEW_UUID" && "$NEW_UUID" != "$OLD_UUID" ]] || die "btrfstune did not change the filesystem UUID"
say "btrfs UUID: $OLD_UUID (eMMC) -> $NEW_UUID (SD)"

LOOP="$(losetup --find --show "$WORK/root.btrfs")"
mount -t btrfs "$LOOP" "$MNT"
R="$MNT/root"
[[ -d "$R/etc" ]] || die "no 'root' subvolume"
sed -i "s/UUID=$OLD_UUID/UUID=$NEW_UUID/g" "$R/etc/fstab"
grep -q "UUID=$NEW_UUID" "$R/etc/fstab" && ! grep -q "UUID=$OLD_UUID" "$R/etc/fstab" \
    || die "fstab UUID rewrite failed"
say "fstab now mounts / /home /var by the SD UUID"
echo "c20e-fedora-sd" > "$R/etc/hostname"

# ---- the installer: bundle + guided wrapper + launcher ----------------------
I="$R/usr/local/share/c20e-installer"
install -d "$I/boot/extlinux"
say "copying the eMMC bundle onto the SD root ($(du -h "$BUNDLE/fedora-root.btrfs.zst" | cut -f1))..."
cp "$BUNDLE/fedora-root.btrfs.zst" "$BUNDLE/manifest" "$I/"
cp "$BUNDLE/boot/Image" "$BUNDLE/boot/rk3562.dtb" "$I/boot/"
cp "$BUNDLE/boot/extlinux/extlinux.conf" "$I/boot/extlinux/"
cp "$REPO/bootloader/upstream-idbloader.img" "$REPO/bootloader/upstream-u-boot.itb" "$I/"
install -m0755 "$REPO/install-c20e-fedora-emmc.sh" "$I/install-c20e-fedora-emmc.sh"
install -m0755 "$REPO/overlay/installer/c20e-install-to-emmc" "$R/usr/local/bin/c20e-install-to-emmc"
install -m0644 "$REPO/overlay/installer/c20e-install-to-emmc.desktop" "$R/usr/share/applications/c20e-install-to-emmc.desktop"
grep -q "root=PARTUUID=$FEDORA_ROOT_PARTUUID" "$I/boot/extlinux/extlinux.conf" \
    || die "bundle extlinux.conf does not point at the eMMC root"
[[ "$(sha256sum "$I/fedora-root.btrfs.zst" | cut -d' ' -f1)" == "$ROOT_SHA256" ]] || die "bundle copy checksum mismatch"
say "installer bundle + launcher installed (bundle checksum re-verified on the SD root)"

sync; umount "$MNT"; losetup -d "$LOOP"; LOOP=""

# ---- SD boot partition: same menu, pointing at the SD root -----------------
C20E_ROOT_PARTUUID="$SD_ROOT_PARTUUID" C20E_BOOTPART_OUT="$WORK/boot-p3.vfat" \
    "$REPO/make-c20e-fedora-bootpart.sh" graphical >/dev/null
MTOOLS_SKIP_CHECK=1 mtype -i "$WORK/boot-p3.vfat" ::/extlinux/extlinux.conf | grep -q "root=PARTUUID=$SD_ROOT_PARTUUID" \
    || die "SD boot menu does not point at the SD root"
say "SD boot partition built (root=PARTUUID=$SD_ROOT_PARTUUID, default: desktop)"

# ---- assemble the card image -------------------------------------------------
say "assembling $IMG ($(( TOTAL / 2048 )) MiB, sparse)..."
truncate -s $(( TOTAL * 512 )) "$IMG"
sfdisk -q "$IMG" <<EOF
label: gpt
first-lba: 34
start=$IDB_SECTOR,  size=1053,   name="idbloader"
start=$UB_SECTOR,   size=8192,   name="uboot"
start=$BOOT_START,  size=$BOOT_SIZE, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="boot", attrs="LegacyBIOSBootable"
start=$ROOT_START,  size=$ROOT_SECTORS_SD, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$SD_ROOT_PARTUUID, name="rootfs"
EOF
dd if="$REPO/bootloader/upstream-idbloader.img" of="$IMG" bs=512 seek=$IDB_SECTOR conv=notrunc status=none
dd if="$REPO/bootloader/upstream-u-boot.itb"    of="$IMG" bs=512 seek=$UB_SECTOR  conv=notrunc status=none
dd if="$WORK/boot-p3.vfat" of="$IMG" bs=512 seek=$BOOT_START conv=notrunc,sparse status=none
dd if="$WORK/root.btrfs"   of="$IMG" bs=1M  seek=$(( ROOT_START / 2048 )) conv=notrunc,sparse status=none
rm -rf "$WORK"

# ---- verify ------------------------------------------------------------------
[[ "$(sfdisk --part-uuid "$IMG" 4 | tr A-F a-f)" == "$SD_ROOT_PARTUUID" ]] || die "p4 PARTUUID wrong"
cmp -s -n "$(stat -c%s "$REPO/bootloader/upstream-idbloader.img")" "$REPO/bootloader/upstream-idbloader.img" \
    <(dd if="$IMG" bs=512 skip=$IDB_SECTOR count=1053 status=none) || die "idbloader not at sector $IDB_SECTOR"
[[ "$(dd if="$IMG" bs=1 skip=$(( ROOT_START*512 + 0x10040 )) count=8 status=none)" == "_BHRfS_M" ]] || die "no btrfs on p4"
say "compressing (the embedded bundle is already zstd, so expect ~5 GB)..."
zstd -T0 -3 -q -f "$IMG" -o "$IMG.zst"
( cd "$OUT" && sha256sum "$(basename "$IMG").zst" > "$(basename "$IMG").zst.sha256" )
[[ "${KEEP_RAW:-0}" == 1 ]] || rm -f "$IMG"
chown -R "${SUDO_USER:-root}:" "$OUT" 2>/dev/null || true

echo
say "done: $IMG.zst ($(du -h "$IMG.zst" | cut -f1)), sha256 in $IMG.zst.sha256"
say "  root fs UUID $NEW_UUID, PARTUUID $SD_ROOT_PARTUUID, $ROOT_GIB GiB root partition"
say "write it to a card (16 GB or larger) -- check the device name first with lsblk:"
say "  zstd -dc $IMG.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
