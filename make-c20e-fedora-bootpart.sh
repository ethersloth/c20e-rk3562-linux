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
# Entries (only the default is reachable: the U-Boot menu is on the internal
# UART). Once Fedora has SSH, change the default from Fedora itself --
# `mount LABEL=C20EBOOT /mnt` and edit /mnt/extlinux/extlinux.conf -- instead
# of a loader-mode write-boot.
#   fedora-text        text mode, c20e units forced on (systemd.wants)
#   fedora-text-nogpu  same, Panfrost never probed (initcall_blacklist) -- for
#                      telling GPU faults from display-controller faults
#   fedora-log         text mode + FAT boot logger (no console, no network)
#   fedora             the desktop
#
# Usage: ./make-c20e-fedora-bootpart.sh [text|nogpu|log|graphical]   (default: text)
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/out/fedora-emmc"
OUT="$SRC/boot-p3.vfat"
DEFAULT="${1:-text}"
BOOT_SECTORS=524288            # p3 size, as written by install-c20e-fedora-emmc.sh

die(){ echo "ERROR: $*" >&2; exit 1; }
case "$DEFAULT" in text) DEF=fedora-text ;; graphical) DEF=fedora ;; log) DEF=fedora-log ;; nogpu) DEF=fedora-text-nogpu ;;
    *) die "default must be text|graphical|log|nogpu" ;; esac
for f in manifest boot/Image boot/rk3562.dtb; do [[ -f "$SRC/$f" ]] || die "missing $SRC/$f (run prepare-c20e-fedora.sh)"; done
command -v mcopy >/dev/null || die "mtools (mcopy) not installed"
# shellcheck disable=SC1091
. "$SRC/manifest"

# Fedora's systemd does a FULL preset on first boot (/etc/machine-id was
# "uninitialized" in the image): every unit not in Fedora's preset lists is
# DISABLED -- including the C20e services and the ttyGS0 USB console getty.
# Verified from the boot journal 2026-09-21: none of them ran. systemd.wants=
# starts them regardless of enablement, so a board that lost its enable links
# still gets its DDR pin (without which the GUI corrupts memory) and USB
# console. The permanent fix is the preset file install-c20e-board-support.sh
# now installs. earlycon/ttyS0 dropped: that UART needs the case opened, and
# U-Boot's 1023-byte append limit needs the room.
WANTS_MIN="systemd.wants=c20e-dvfs-policy.service systemd.wants=c20e-usb-debug.service systemd.wants=serial-getty@ttyGS0.service"
WANTS_ALL="$WANTS_MIN systemd.wants=c20e-bt-bringup.service systemd.wants=c20e-camera.service"
BASE="console=tty1 root=PARTUUID=$FEDORA_ROOT_PARTUUID rootfstype=btrfs rootflags=subvol=root,compress=zstd:1 rw rootwait panic=10 enforcing=0 video=DSI-1:800x1280@60,rotate=90"
# Boot logger for the text entry, no rootfs change needed: PID 1 starts as bash,
# forks a logger, then execs systemd (still PID 1, so the boot is otherwise
# normal). Every 30 s the logger mounts this FAT partition (label C20EBOOT) at
# /mnt and overwrites j.txt (journal), k.txt (dmesg) and s.txt (jobs, failed
# units, USB gadget/role state, process list), so they are current even if the
# boot hangs; each ends at an ==END== line. The files are PRE-ALLOCATED here,
# before the kernel, and overwritten in place (dd conv=notrunc), because
# rockusb in this U-Boot cannot read eMMC sectors >= 65536 (32 MiB; reads
# return 0xcc) -- a freshly allocated file lands after the 43 MB Image, out of
# reach. Read them back in loader mode with
#     sudo ./c20e-emmc-bootloader-rockusb.sh read-log
# Constraints, all enforced below:
#   - U-Boot (cmd/pxe.c) refuses an append line of 1024+ bytes ("bootarg
#     overflow") -- CONFIG_SYS_CBSIZE is 1024 on rk3562
#   - U-Boot's cli_simple_process_macros expands $, and eats \ and ' -- so none
#   - the kernel strips only the outer pair of double quotes -- so none inside
LOGGER='while sleep 30;do mount -o sync LABEL=C20EBOOT /mnt 2>/dev/null;cd /mnt||continue;{ journalctl -b -o short-monotonic 2>&1|tail -c 4000000;echo ==END==;}|dd of=j.txt conv=notrunc status=none;{ dmesg|tail -c 1900000;echo ==END==;}|dd of=k.txt conv=notrunc status=none;{ systemctl list-jobs;systemctl --failed;ls /sys/class/udc /dev/ttyGS0;cat /sys/kernel/debug/usb/fe500000.usb/mode /sys/class/usb_role/*/role /var/log/c20e-usb-debug.log;ps -eo pid,stat,etime,args;echo ==END==;} 2>&1|tail -c 200000|dd of=s.txt conv=notrunc status=none;cd /;sync;done'
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
  menu label Fedora (text mode)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE $WANTS_MIN systemd.unit=multi-user.target systemd.show_status=1 plymouth.enable=0

label fedora-text-nogpu
  menu label Fedora (text mode, Panfrost not loaded)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE $WANTS_MIN systemd.unit=multi-user.target systemd.show_status=1 plymouth.enable=0 initcall_blacklist=panfrost_driver_init

label fedora-log
  menu label Fedora (text mode, boot log to this partition)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE $WANTS_MIN $DIAG

label fedora
  menu label Fedora (desktop)
  kernel /Image
  fdt /rk3562.dtb
  append $BASE $WANTS_ALL
EOF

rm -f "$OUT"
truncate -s $((BOOT_SECTORS*512)) "$OUT"
mkfs.vfat -F 32 -n C20EBOOT "$OUT" >/dev/null
export MTOOLS_SKIP_CHECK=1
# Log files FIRST, so they take the first clusters (below eMMC sector 65536).
for spec in j.txt:4194304 k.txt:2097152 s.txt:262144; do
    head -c "${spec#*:}" /dev/zero | tr '\0' '\n' > "$T/${spec%%:*}"
    mcopy -i "$OUT" "$T/${spec%%:*}" "::/${spec%%:*}"
done
mmd -i "$OUT" ::/extlinux
mcopy -i "$OUT" "$SRC/boot/Image" "$SRC/boot/rk3562.dtb" ::/
mcopy -i "$OUT" "$T/extlinux.conf" ::/extlinux/extlinux.conf
# /c20e: live repair kit for a Fedora root prepared before the BSP installer
# handled Fedora's first-boot preset and the Wi-Fi firmware (see
# tools/c20e-fedora-live-fixup.sh). Placed last; only Linux reads it.
mmd -i "$OUT" ::/c20e ::/c20e/firmware
mcopy -i "$OUT" "$REPO/tools/c20e-fedora-live-fixup.sh" "$REPO/overlay/c20e.preset" ::/c20e/
mcopy -i "$OUT" "$REPO"/overlay/firmware/*.bin ::/c20e/firmware/
cp "$T/extlinux.conf" "$SRC/boot/extlinux/extlinux.conf"   # keep boot/ in step with the image
L=$(grep 'append' "$T/extlinux.conf" | sed 's/^ *append //' | awk '{ if (length($0) > m) m = length($0) } END { print m }')
[[ $L -le 1000 ]] || die "longest append line is $L bytes; U-Boot's limit is 1023 (keep margin)"
echo "[bootpart] $OUT  (default: $DEF, longest append $L bytes)"
mdir -i "$OUT" ::/ ::/extlinux | grep -vE '^$|Volume|Directory|files'
