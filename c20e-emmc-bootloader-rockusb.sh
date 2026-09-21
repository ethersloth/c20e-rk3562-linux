#!/usr/bin/env bash
# Disable or restore the C20e eMMC bootloader over USB (rockusb), from the
# LAPTOP, with no working OS on the tablet.
#
# Why this exists: the SD card does NOT take priority over the eMMC on this
# board. Once the eMMC holds a bootable idbloader + u-boot + extlinux, the
# tablet boots the eMMC even with the Debian SD card inserted. If that eMMC OS
# hangs without network or USB console, this is the way back in:
#
#   1. tablet off, USB cable to the laptop
#   2. hold Volume Up, press power, keep holding ~5-10 s (screen stays black)
#   3. `lsusb | grep 2207` shows "USB download gadget" (loader mode)
#   4. sudo ./c20e-emmc-bootloader-rockusb.sh disable
#
# `disable` zeroes ONLY the idbloader (sectors 64..64+N) after checking it is
# the one we installed and saving a copy. The BootROM then finds no loader on
# the eMMC and boots the SD card. Partitions (boot, Fedora root) are untouched.
# `restore` writes the idbloader back, making the eMMC bootable again.
#
# Usage: sudo ./c20e-emmc-bootloader-rockusb.sh disable|restore|check
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
IDB="$REPO/bootloader/upstream-idbloader.img"
SAVE="$REPO/out/emmc-idbloader-readback.bin"
SECTOR=64
BYTES=$(stat -c%s "$IDB")
N=$(( (BYTES + 511) / 512 ))
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[rockusb] $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
command -v rkdeveloptool >/dev/null || die "rkdeveloptool not installed"
rkdeveloptool ld 2>/dev/null | grep -q 'Vid=0x2207' || die "no Rockchip device in loader/maskrom mode (hold Volume Up at power-on)"

readback(){ rkdeveloptool rl $SECTOR $N "$1" >/dev/null || die "read failed"; [[ $(stat -c%s "$1") -eq $((N*512)) ]] || die "short read"; }
is_ours(){ cmp -s -n "$BYTES" "$IDB" "$1"; }
is_zero(){ cmp -s "$1" <(head -c "$(stat -c%s "$1")" /dev/zero); }

case "${1:-}" in
check)
    readback "$TMP/cur"
    if is_ours "$TMP/cur"; then say "eMMC sector $SECTOR: our upstream idbloader (eMMC bootable)"
    elif is_zero "$TMP/cur"; then say "eMMC sector $SECTOR: blank (eMMC not bootable -> SD boots)"
    else say "eMMC sector $SECTOR: something else ($(head -c4 "$TMP/cur" | od -An -c))"; fi ;;
disable)
    readback "$TMP/cur"
    if is_zero "$TMP/cur"; then say "already blank; nothing to do"; exit 0; fi
    is_ours "$TMP/cur" || die "eMMC idbloader is not the one we installed; refusing to touch it"
    mkdir -p "$(dirname "$SAVE")"; cp "$TMP/cur" "$SAVE"; chown "${SUDO_USER:-root}:" "$SAVE" 2>/dev/null || true
    say "verified + saved current idbloader to $SAVE"
    head -c $((N*512)) /dev/zero > "$TMP/zero"
    rkdeveloptool wl $SECTOR "$TMP/zero" >/dev/null || die "write failed"
    readback "$TMP/after"; is_zero "$TMP/after" || die "read-back after write is not blank!"
    say "eMMC idbloader blanked ($N sectors at $SECTOR), verified by read-back"
    say "now: rkdeveloptool rd   (or power-cycle) with the Debian SD card inserted" ;;
restore)
    rkdeveloptool wl $SECTOR "$IDB" >/dev/null || die "write failed"
    readback "$TMP/after"; is_ours "$TMP/after" || die "read-back mismatch after restore!"
    say "eMMC idbloader restored and verified; eMMC is bootable again" ;;
*) die "usage: $0 disable|restore|check" ;;
esac
