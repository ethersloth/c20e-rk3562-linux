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
# Blanking the idbloader alone was NOT enough (2026-09-21): the tablet still
# booted the eMMC's Fedora. U-Boot's distro boot scans every mmc device for a
# partition flagged bootable holding extlinux/extlinux.conf, so whichever
# U-Boot runs can still pick the eMMC's boot partition. `hide-boot` zeroes the
# first 8 sectors (FAT boot sector, FSInfo, backup boot sector) of the eMMC
# boot partition after saving them, so no U-Boot can find extlinux.conf there;
# `unhide-boot` writes them back. `inspect` is read-only.
#
# `dump` (read-only) copies sectors 0..40959 (20 MiB: GPT, every idblock copy,
# u-boot, start of the boot partition) to out/emmc-head-dump.bin for analysis.
#
# Usage: sudo ./c20e-emmc-bootloader-rockusb.sh disable|restore|check|inspect|dump|hide-boot|unhide-boot
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
IDB="$REPO/bootloader/upstream-idbloader.img"
SAVE="$REPO/out/emmc-idbloader-readback.bin"
SECTOR=64
BOOT_START=32768          # eMMC p3 (vfat boot), as written by install-c20e-fedora-emmc.sh
BOOT_SAVE="$REPO/out/emmc-p3-head-readback.bin"
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
inspect)
    # Rockchip BootROMs search for backup idblocks at 512 KiB steps. Android's
    # factory loader may have left copies that our shorter idbloader and the
    # GPT rewrite never overwrote.
    for k in 0 1 2 3 4; do
        s=$((64 + 1024*k))
        rkdeveloptool rl $s 1 "$TMP/s" >/dev/null || die "read failed"
        if is_zero "$TMP/s"; then d="blank"; else d="DATA  first bytes: $(head -c8 "$TMP/s" | od -An -tx1 | tr -s ' ')"; fi
        echo "  sector $s (idblock copy $k): $d"
    done
    rkdeveloptool rl 16384 1 "$TMP/s" >/dev/null
    echo "  sector 16384 (u-boot.itb): $(head -c4 "$TMP/s" | od -An -tx1 | tr -s ' ')   (d0 0d fe ed = FIT)"
    rkdeveloptool rl $BOOT_START 1 "$TMP/s" >/dev/null
    echo "  sector $BOOT_START (boot p3): OEM '$(dd if="$TMP/s" bs=1 skip=3 count=8 status=none | tr -c '[:print:]' .)' fstype '$(dd if="$TMP/s" bs=1 skip=82 count=8 status=none | tr -c '[:print:]' .)'" ;;
hide-boot)
    rkdeveloptool rl $BOOT_START 8 "$TMP/cur" >/dev/null || die "read failed"
    if is_zero "$TMP/cur"; then say "eMMC boot partition already hidden"; exit 0; fi
    [[ "$(dd if="$TMP/cur" bs=1 skip=82 count=5 status=none)" == "FAT32" ]] \
        || die "sector $BOOT_START is not a FAT32 boot sector; refusing"
    mkdir -p "$(dirname "$BOOT_SAVE")"; cp "$TMP/cur" "$BOOT_SAVE"; chown "${SUDO_USER:-root}:" "$BOOT_SAVE" 2>/dev/null || true
    say "saved eMMC boot-partition head to $BOOT_SAVE"
    head -c 4096 /dev/zero > "$TMP/zero"
    rkdeveloptool wl $BOOT_START "$TMP/zero" >/dev/null || die "write failed"
    rkdeveloptool rl $BOOT_START 8 "$TMP/after" >/dev/null; is_zero "$TMP/after" || die "read-back not blank!"
    say "eMMC boot partition hidden (no FAT signature); U-Boot can only boot the SD card now" ;;
unhide-boot)
    [[ -f "$BOOT_SAVE" && $(stat -c%s "$BOOT_SAVE") -eq 4096 ]] || die "no saved $BOOT_SAVE"
    rkdeveloptool wl $BOOT_START "$BOOT_SAVE" >/dev/null || die "write failed"
    rkdeveloptool rl $BOOT_START 8 "$TMP/after" >/dev/null; cmp -s "$BOOT_SAVE" "$TMP/after" || die "read-back mismatch!"
    say "eMMC boot partition restored" ;;
dump)
    D="$REPO/out/emmc-head-dump.bin"; mkdir -p "$REPO/out"
    rkdeveloptool rl 0 40960 "$D" >/dev/null || die "read failed"
    [[ $(stat -c%s "$D") -eq $((40960*512)) ]] || die "short read"
    chown "${SUDO_USER:-root}:" "$D" 2>/dev/null || true
    say "dumped eMMC sectors 0..40959 to $D (read-only)" ;;
*) die "usage: $0 disable|restore|check|inspect|dump|hide-boot|unhide-boot" ;;
esac
