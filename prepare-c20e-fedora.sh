#!/usr/bin/env bash
# Prepare a Fedora KDE Plasma Mobile root filesystem for the C20e eMMC.
# Runs on the LAPTOP with sudo. Writes nothing to the tablet.
#
# Fedora's aarch64 disk image boots via EFI + GRUB on Fedora's own kernel. The
# RK3562 needs neither: it boots our U-Boot, which reads extlinux.conf and
# starts OUR kernel (6.1 vendor BSP, Panfrost GPU stack). So we keep Fedora's
# userspace and replace everything around it:
#
#   - take Fedora's btrfs root partition as-is (subvolumes root/home/var, its
#     UUID, its SELinux labels) -- copied in whole SECTORS, since its size
#     (18685919 sectors) is odd and not a whole number of MiB
#   - drop the /boot and /boot/efi fstab entries: those partitions do not exist
#     in our layout, and systemd would wait on them and fall to emergency mode
#   - install our kernel's modules and the C20e board-support package
#   - set SELinux permissive for bring-up, so a labelling problem cannot lock
#     the first boot out
#   - enable the USB serial console as a way in that does not depend on the GPU
#     or Wi-Fi, since Fedora creates its first user in a GRAPHICAL wizard
#     (plasma-setup) that cannot run if the display stack fails
#
# Output: out/fedora-emmc/{fedora-root.btrfs.zst, boot/, manifest}
#
# Usage: sudo ./prepare-c20e-fedora.sh [path/to/Fedora-*.aarch64.raw]
set -Eeuo pipefail

REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
RAW="${1:-$(ls "$REPO"/out/fedora/Fedora-KDE-Mobile-Disk-*.aarch64.raw 2>/dev/null | head -1)}"
OUT="$REPO/out/fedora-emmc"
KSRC="$REPO/src/kernel"
MNT="$(mktemp -d)"
LOOP=""

# Fixed identity for the eMMC root partition. extlinux.conf must name it, and
# the kernel resolves root=PARTUUID= without an initramfs (it cannot resolve
# root=UUID=). Deliberately different from the Debian SD card's rootfs
# (c0ffee11-...) so the two can never be confused when both are present.
FEDORA_ROOT_PARTUUID="c20ef00d-0000-4000-8000-000000000004"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[fedora-prep] $*"; }
cleanup(){
    mountpoint -q "$MNT" && umount "$MNT" || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -f "$RAW" ]] || die "no Fedora raw image (pass its path)"
[[ -f "$KSRC/arch/arm64/boot/Image" ]] || die "no kernel Image; run ./build.sh extboot --gpu-stack panfrost"
grep -qx 'CONFIG_DRM_PANFROST=y' "$KSRC/.config" \
    || die "the kernel in $KSRC is not a Panfrost build (rebuild with --gpu-stack panfrost)"
grep -qx 'CONFIG_BTRFS_FS=y' "$KSRC/.config" || die "kernel lacks btrfs; Fedora's root is btrfs"
# Without the all-clocks patch the first GPU open freezes the SoC (see
# overlay/drivers/gpu/drm/panfrost/panfrost_device.c). Refuse to build without it.
grep -q 'enabled all %d DT clocks' "$KSRC/drivers/gpu/drm/panfrost/panfrost_device.c" \
    || die "kernel tree lacks the Panfrost all-clocks fix; rebuild with ./build.sh extboot --gpu-stack panfrost"
[[ "$KSRC/arch/arm64/boot/Image" -nt "$KSRC/drivers/gpu/drm/panfrost/panfrost_device.c" ]] \
    || die "kernel Image is older than the Panfrost fix; rebuild the kernel"
KDTB="$KSRC/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
[[ -f "$KDTB" ]] || die "missing $KDTB"
KREL="$(make -s -C "$KSRC" ARCH=arm64 kernelrelease)"

# Exact btrfs partition geometry, read from the image, in sectors.
read -r START SIZE < <(sfdisk -d "$RAW" | awk -F'[=,]' '$1 ~ /3 :/ || /raw3 /{gsub(/ /,"");print $2, $4}')
[[ -n "${START:-}" && -n "${SIZE:-}" ]] || die "could not read partition 3 geometry from $RAW"
say "Fedora image : $RAW"
say "btrfs part   : start=$START size=$SIZE sectors ($((SIZE*512)) bytes)"
say "kernel       : $KREL (Panfrost)"

rm -rf "$OUT"; mkdir -p "$OUT/boot/extlinux"
ROOTIMG="$OUT/fedora-root.btrfs"

say "extracting btrfs root (sector-exact, sparse)..."
dd if="$RAW" of="$ROOTIMG" bs=512 skip="$START" count="$SIZE" conv=sparse status=none
GOT=$(stat -c%s "$ROOTIMG")
[[ "$GOT" -eq $((SIZE*512)) ]] || die "extracted $GOT bytes, expected $((SIZE*512))"
say "extracted $GOT bytes (exact)"

LOOP="$(losetup --find --show "$ROOTIMG")"
mount -t btrfs "$LOOP" "$MNT"                 # top level: subvolumes are dirs
R="$MNT/root"
[[ -d "$R/etc" ]] || die "no 'root' subvolume in the Fedora btrfs"
say "mounted Fedora root subvolume"

# ---- fstab: remove partitions that will not exist ----------------------
cp -a "$R/etc/fstab" "$R/etc/fstab.fedora-original"
awk '
  $2=="/boot" || $2=="/boot/efi" {
      print "# removed for the C20e: no separate /boot or EFI partition; the"
      print "# board boots U-Boot -> extlinux.conf -> kernel directly."
      print "# " $0; next }
  { print }' "$R/etc/fstab.fedora-original" > "$R/etc/fstab"
say "fstab: /boot and /boot/efi entries removed (original kept as fstab.fedora-original)"

# ---- kernel modules ---------------------------------------------------
say "installing kernel modules for $KREL..."
make -s -C "$KSRC" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     INSTALL_MOD_PATH="$R" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$R/lib/modules/$KREL/build" "$R/lib/modules/$KREL/source"

# ---- Fedora kernel packages: remove and exclude ---------------------------
# This board boots OUR kernel from the eMMC boot partition; Fedora's kernel
# packages only fill /boot on the root fs (nothing reads it) and /lib/modules
# -- ~400 MB each, and every update adds another (seen 2026-09-22: 6.19.10 from
# the image plus 7.2.6 from the first update). --noscripts: their scriptlets
# (kernel-install, dracut) are aarch64 and pointless here; the host rpm only
# edits the database and deletes files. linux-firmware stays.
FEDKERNELS=$(rpm --root "$R" -qa 'kernel' 'kernel-core' 'kernel-modules' 'kernel-modules-core' 'kernel-modules-extra' 2>/dev/null || true)
if [[ -n "$FEDKERNELS" ]]; then
    # shellcheck disable=SC2086
    rpm --root "$R" -e --nodeps --noscripts $FEDKERNELS
    say "removed Fedora kernel packages: $(echo $FEDKERNELS | tr '\n' ' ')"
fi
if ! grep -q '^excludepkgs' "$R/etc/dnf/dnf.conf"; then
    cat >> "$R/etc/dnf/dnf.conf" <<'EOF'

# C20e: this board boots its own vendor kernel (6.1.x, Panfrost) from the eMMC
# boot partition via U-Boot + extlinux. Fedora kernel packages install into
# /boot on the root filesystem, which nothing reads -- ~400 MB per kernel.
excludepkgs=kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-uki-virt
EOF
    say "dnf: Fedora kernel packages excluded"
fi

# ---- board support (Wi-Fi, BT, DVFS pin, cameras, USB console) ---------
"$REPO/install-c20e-board-support.sh" "$R"

# ---- bring-up safety ----------------------------------------------------
# Permissive, not disabled: labels stay maintained, denials are only logged,
# so switching to enforcing later needs no relabel.
if [[ -f "$R/etc/selinux/config" ]]; then
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$R/etc/selinux/config"
    say "SELinux set to permissive for bring-up"
fi

# Root autologin on the USB serial console ONLY. Physical cable required.
# TEMPORARY: remove /etc/systemd/system/serial-getty@ttyGS0.service.d once
# Fedora's own first-user setup has completed.
install -d "$R/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyGS0.service.d/c20e-bringup-autologin.conf" <<'EOF'
# C20e bring-up ONLY: root autologin on the USB serial gadget, so the board is
# reachable even if the GPU, the display, plasma-setup or Wi-Fi fail.
# Requires physical USB access. Delete this file once setup is complete.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
EOF
say "TEMPORARY root autologin on ttyGS0 (USB serial) configured"

echo "c20e-fedora" > "$R/etc/hostname"

sync; umount "$MNT"; losetup -d "$LOOP"; LOOP=""

# ---- boot partition contents -------------------------------------------
cp "$KSRC/arch/arm64/boot/Image" "$OUT/boot/Image"
cp "$KDTB" "$OUT/boot/rk3562.dtb"

say "compressing root image (for transfer to the tablet)..."
zstd -T0 -3 -q --rm -f "$ROOTIMG" -o "$ROOTIMG.zst"

cat > "$OUT/manifest" <<EOF
FEDORA_ROOT_PARTUUID=$FEDORA_ROOT_PARTUUID
ROOT_SECTORS=$SIZE
KERNEL=$KREL
ROOT_SHA256=$(sha256sum "$ROOTIMG.zst" | cut -d' ' -f1)
EOF

# Boot menu + the 256 MiB FAT boot-partition image, from the same generator the
# rockusb/SSH repair path uses, so they cannot drift apart. Default: desktop.
# (It needs the manifest above for the root PARTUUID and kernel version.)
"$REPO/make-c20e-fedora-bootpart.sh" graphical
chown -R "${SUDO_USER:-root}:" "$OUT" 2>/dev/null || true

echo
say "done:"
ls -la "$OUT" "$OUT/boot"
cat "$OUT/manifest"
