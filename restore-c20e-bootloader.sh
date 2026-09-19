#!/usr/bin/env bash
# Write the C20e factory bootchain onto a card, without touching boot or rootfs.
#
# Use this to repair a card that was flashed with a full image built before the
# factory bootchain was wired in, or after any experiment that overwrote the
# bootloader. Symptom it fixes: the tablet is completely silent -- no console
# output even on the linux-debug label, no USB gadget, no backlight activity.
#
# Writes by OFFSET rather than to /dev/sdX1 and /dev/sdX2, so it works even if
# the partition table is missing or wrong.
#
# Usage: sudo ./restore-c20e-bootloader.sh /dev/sdX
set -Eeuo pipefail

DEV="${1:-}"
MODE="${2:-upstream}"     # upstream | factory | clear
REPO="${RKDEBIAN_REPO:-/home/${SUDO_USER:-$USER}/Desktop/workspace/rk3562deb}"

# Default to the upstream bootchain: it is the one this tablet is known to boot.
# The card was originally created by flashing tech4bot's released image, which
# booted, and every later fix was layered on top of it. deploy-c20e-sd.sh only
# ever replaced Image and rk3562.dtb, so that bootloader survived untouched --
# which is why it kept working and why a full-image flash broke it.
#
# build.sh clones U-Boot at branch HEAD, so a build today produces a DIFFERENT
# U-Boot (commit b2adc656) than upstream's release (commit 30d6e6f). That newer
# commit has never been shown to boot this board.
case "$MODE" in
    upstream)
        IDB="$REPO/bootloader/upstream-idbloader.img"
        UBOOT="$REPO/bootloader/upstream-u-boot.itb" ;;
    factory)
        # The Android bootchain carved from the eMMC. Tried during debugging and
        # it did NOT boot Linux; kept only for completeness.
        IDB="$REPO/bootloader/c20e-factory-idbloader.img"
        UBOOT="$REPO/bootloader/c20e-factory-uboot.itb" ;;
    clear) IDB=""; UBOOT="" ;;
    *) echo "ERROR: mode must be upstream, factory or clear" >&2; exit 1 ;;
esac

IDB_SEEK=64        # 32 KiB  / 512
UB_SEEK=16384      # 8 MiB   / 512
IDB_LEN=1024       # 512 KiB / 512
UB_LEN=8192        # 4 MiB   / 512

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DEV" ]] || die "Usage: sudo $0 /dev/sdX [upstream|factory|clear]"
[[ "$DEV" == /dev/sd? ]] || die "Refusing non-/dev/sdX target: $DEV"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
lsblk -nrpo MOUNTPOINTS "$DEV" | grep -q '/' && die "A partition on $DEV is mounted."

echo "Target:"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN "$DEV"
echo

if [[ "$MODE" == "clear" ]]; then
    # Zero the bootloader regions so the BootROM finds nothing on the card.
    #
    # On this board the SD card does NOT boot standalone: the eMMC bootloader
    # chain-loads Linux from it (which is why pulling the card returns you to
    # Android, and why the running system reported the FACTORY U-Boot build
    # string). If the BootROM finds something at sector 64 it will try to use
    # it, and a bootloader it cannot use leaves the board dead -- black screen,
    # and Android will not boot either while the card is inserted.
    #
    # Leaving these regions empty is therefore the correct state for a card
    # that is meant to be chain-loaded.
    echo "Clearing bootloader regions (offset 32K and 8M)."
    echo "Boot and rootfs partitions are NOT touched."
    echo
    read -r -p "Type C20E to clear the bootloader on $DEV: " CONFIRM
    [[ "$CONFIRM" == "C20E" ]] || die "Cancelled."
    dd if=/dev/zero of="$DEV" bs=512 seek="$IDB_SEEK" count="$IDB_LEN" conv=fsync status=none
    dd if=/dev/zero of="$DEV" bs=512 seek="$UB_SEEK"  count="$UB_LEN"  conv=fsync status=none
    sync
    echo "Cleared. Re-run without 'clear' to put the factory bootchain back."
    exit 0
fi

[[ -f "$IDB" ]] || die "missing $IDB (run ./extract-c20e-factory-bootloader.sh)"
[[ -f "$UBOOT" ]] || die "missing $UBOOT (run ./extract-c20e-factory-bootloader.sh)"
# Upstream/built loaders are "LDR " containers; the eMMC factory one is "RKNS".
# Both are valid here, so only reject something that is neither.
head -c4 "$IDB" | grep -qE 'RKNS|LDR ' || die "$IDB is not a recognised Rockchip loader"
[[ "$(xxd -p -l4 "$UBOOT")" == "d00dfeed" ]] || die "$UBOOT is not a FIT image"

echo "Writing:"
echo "  $(basename "$IDB")   -> offset 32K  ($(stat -c%s "$IDB") bytes)"
echo "  $(basename "$UBOOT") -> offset 8M   ($(stat -c%s "$UBOOT") bytes)"
echo "Boot and rootfs partitions are NOT touched."
echo
read -r -p "Type C20E to write the bootloader to $DEV: " CONFIRM
[[ "$CONFIRM" == "C20E" ]] || die "Cancelled."

dd if="$IDB"   of="$DEV" bs=512 seek="$IDB_SEEK" conv=fsync status=none
dd if="$UBOOT" of="$DEV" bs=512 seek="$UB_SEEK"  conv=fsync status=none
sync

# Read back and compare, since a silent failure here is very expensive to debug.
tmp_idb="$(mktemp)"; tmp_ub="$(mktemp)"
trap 'rm -f "$tmp_idb" "$tmp_ub"' EXIT
dd if="$DEV" of="$tmp_idb" bs=512 skip="$IDB_SEEK" count=$(( $(stat -c%s "$IDB") / 512 )) status=none
dd if="$DEV" of="$tmp_ub"  bs=512 skip="$UB_SEEK"  count=$(( $(stat -c%s "$UBOOT") / 512 )) status=none
cmp -s "$IDB" "$tmp_idb"   || die "idbloader verification FAILED."
cmp -s "$UBOOT" "$tmp_ub"  || die "U-Boot verification FAILED."

echo "Verified both regions read back byte-identical."
echo "SUCCESS - the card should boot again."
