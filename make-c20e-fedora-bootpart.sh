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
# Boot logger for the text entry, no rootfs change needed: PID 1 starts as bash,
# forks a logger, then execs systemd (still PID 1, so the boot is otherwise
# normal). Every 30 s the logger mounts this FAT partition (label C20EBOOT) at
# /mnt and rewrites j.txt (journal), k.txt (dmesg) and s.txt (jobs, failed
# units, USB gadget/role state, process list), so they are current even if the
# boot hangs. Read them back in loader mode with
#     sudo ./c20e-emmc-bootloader-rockusb.sh read-log
# Constraints, all enforced below:
#   - U-Boot (cmd/pxe.c) refuses an append line of 1024+ bytes ("bootarg
#     overflow") -- CONFIG_SYS_CBSIZE is 1024 on rk3562
#   - U-Boot's cli_simple_process_macros expands $, and eats \ and ' -- so none
#   - the kernel strips only the outer pair of double quotes -- so none inside
LOGGER='while sleep 30;do mount -o sync LABEL=C20EBOOT /mnt 2>/dev/null;cd /mnt||continue;journalctl -b -o short-monotonic>j.txt 2>&1;dmesg>k.txt;{ systemctl list-jobs;systemctl --failed;ls /sys/class/udc /dev/ttyGS0;cat /sys/kernel/debug/usb/fe500000.usb/mode /sys/class/usb_role/*/role /var/log/c20e-usb-debug.log;ps -eo pid,stat,etime,args;}>s.txt 2>&1;cd /;sync;done'
DIAG="systemd.unit=multi-user.target systemd.show_status=1 plymouth.enable=0 init=/usr/bin/bash -- -c \"( $LOGGER )& exec /usr/lib/systemd/systemd\""
case "$LOGGER" in *[\$\'\\\"]*) die "logger contains \$, ', \\ or a double quote; U-Boot/kernel would mangle it" ;; esac
[[ "$DIAG" != *'$'* ]] || die "logger contains a dollar sign; U-Boot would expand it"

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
  append $BASE $DIAG

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
L=$(grep -m1 'init=' "$T/extlinux.conf" | sed 's/^ *append //' | tr -d '\n' | wc -c)
[[ $L -le 1000 ]] || die "diagnostic append line is $L bytes; U-Boot's limit is 1023 (keep margin)"
echo "[bootpart] $OUT  (default: $DEF, diag cmdline $L bytes)"
mdir -i "$OUT" ::/ ::/extlinux | grep -vE '^$|Volume|Directory|files'
