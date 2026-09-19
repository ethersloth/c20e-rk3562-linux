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
REPO="${RKDEBIAN_REPO:-/home/${SUDO_USER:-$USER}/Desktop/workspace/rk3562deb}"
IDB="$REPO/bootloader/c20e-factory-idbloader.img"
UBOOT="$REPO/bootloader/c20e-factory-uboot.itb"

IDB_SEEK=64        # 32 KiB  / 512
UB_SEEK=16384      # 8 MiB   / 512

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DEV" ]] || die "Usage: sudo $0 /dev/sdX"
[[ "$DEV" == /dev/sd? ]] || die "Refusing non-/dev/sdX target: $DEV"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
[[ -f "$IDB" ]] || die "missing $IDB (run ./extract-c20e-factory-bootloader.sh)"
[[ -f "$UBOOT" ]] || die "missing $UBOOT (run ./extract-c20e-factory-bootloader.sh)"
head -c4 "$IDB" | grep -q 'RKNS' || die "$IDB is not an RKNS idblock"
[[ "$(xxd -p -l4 "$UBOOT")" == "d00dfeed" ]] || die "$UBOOT is not a FIT image"
lsblk -nrpo MOUNTPOINTS "$DEV" | grep -q '/' && die "A partition on $DEV is mounted."

echo "Target:"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,TRAN "$DEV"
echo
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
