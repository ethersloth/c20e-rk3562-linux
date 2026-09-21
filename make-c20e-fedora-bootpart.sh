#!/usr/bin/env bash
# Build the eMMC boot partition (p3) for Fedora as a 256 MiB FAT32 image file,
# on the laptop, WITHOUT root, so it can be written over USB in loader mode:
#     sudo ./c20e-emmc-bootloader-rockusb.sh write-boot out/fedora-emmc/boot-p3.vfat
#
# The extlinux menu has a diagnostic default and the normal desktop entry:
#   fedora-text  multi-user.target (no desktop), systemd status on screen, no
#                splash -- so a hang shows WHERE it stops, and a desktop failure
#                cannot take the USB console down with it
#   fedora       the normal graphical boot
#
# Usage: ./make-c20e-fedora-bootpart.sh [text|graphical]   (default entry; text)
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/out/fedora-emmc"
OUT="$SRC/boot-p3.vfat"
DEFAULT="${1:-text}"
BOOT_SECTORS=524288            # p3 size, as written by install-c20e-fedora-emmc.sh

die(){ echo "ERROR: $*" >&2; exit 1; }
case "$DEFAULT" in text) DEF=fedora-text ;; graphical) DEF=fedora ;; *) die "default must be text|graphical" ;; esac
for f in manifest boot/Image boot/rk3562.dtb; do [[ -f "$SRC/$f" ]] || die "missing $SRC/$f (run prepare-c20e-fedora.sh)"; done
command -v mcopy >/dev/null || die "mtools (mcopy) not installed"
# shellcheck disable=SC1091
. "$SRC/manifest"

BASE="earlycon=uart8250,mmio32,0xff210000 console=ttyS0,1500000n8 console=tty1 root=PARTUUID=$FEDORA_ROOT_PARTUUID rootfstype=btrfs rootflags=subvol=root,compress=zstd:1 rw rootwait panic=10 enforcing=0 video=DSI-1:800x1280@60,rotate=90"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/extlinux.conf" <<EOF
# C20e Fedora KDE Plasma Mobile -- kernel $KERNEL (Panfrost), no initramfs,
# root by PARTUUID. Default entry: $DEF
default $DEF
timeout 30
menu title C20e Fedora

label fedora-text
  menu label Fedora (text mode, diagnostic)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE systemd.unit=multi-user.target systemd.show_status=1 plymouth.enable=0

label fedora
  menu label Fedora (desktop)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE
EOF

rm -f "$OUT"
truncate -s $((BOOT_SECTORS*512)) "$OUT"
mkfs.vfat -F 32 -n C20EBOOT "$OUT" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$OUT" ::/extlinux
mcopy -i "$OUT" "$SRC/boot/Image" "$SRC/boot/rk3562.dtb" ::/
mcopy -i "$OUT" "$T/extlinux.conf" ::/extlinux/extlinux.conf
cp "$T/extlinux.conf" "$SRC/boot/extlinux/extlinux.conf"   # keep boot/ in step with the image
echo "[bootpart] $OUT  (default: $DEF)"
mdir -i "$OUT" ::/ ::/extlinux | grep -vE '^$|Volume|Directory|files'
