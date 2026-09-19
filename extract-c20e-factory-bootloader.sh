#!/usr/bin/env bash
# Carve the C20e factory bootchain out of the eMMC dump into bootloader/.
#
# Why this exists: build.sh cannot produce a bootloader that boots this board.
# It ships rk3562_spl_loader_*.bin, which is the USB maskrom DOWNLOAD loader
# ("LDR " container). SD/eMMC boot needs an idblock ("RKNS"), which the BootROM
# reads from sector 64. Write the wrong one and the board is silent: no console,
# no USB, nothing -- it looks like dead hardware.
#
# The factory chain lives in the eMMC dump at the same offsets the SD card uses:
#   32 KiB  RKNS idblock      (Rockchip writes 5 copies, 512 KiB apart)
#   8 MiB   U-Boot FIT        (backup copy at 12 MiB)
# which line up with genimage.cfg's idbloader@32K and uboot@8M.
set -Eeuo pipefail

REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
DUMP="${1:-$REPO/c20e-backup/emmc-first-16MiB.bin}"
OUT="$REPO/bootloader"

IDB_OFF=32768;     IDB_LEN=524288      # 32 KiB .. next idblock copy at 544 KiB
UB_OFF=8388608;    UB_LEN=4194304      # 8 MiB  .. backup FIT at 12 MiB

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ -f "$DUMP" ]] || die "eMMC dump not found: $DUMP"
[[ $(stat -c%s "$DUMP") -ge $((UB_OFF + UB_LEN)) ]] || die "dump is too small to contain the U-Boot FIT"

mkdir -p "$OUT"
dd if="$DUMP" of="$OUT/c20e-factory-idbloader.img" bs=1 skip="$IDB_OFF" count="$IDB_LEN" status=none
dd if="$DUMP" of="$OUT/c20e-factory-uboot.itb"     bs=1 skip="$UB_OFF"  count="$UB_LEN"  status=none

# Both magics must be right; a bad idbloader fails invisibly at boot.
head -c4 "$OUT/c20e-factory-idbloader.img" | grep -q 'RKNS' \
    || die "extracted idbloader is not an RKNS idblock"
[[ "$(xxd -p -l4 "$OUT/c20e-factory-uboot.itb")" == "d00dfeed" ]] \
    || die "extracted U-Boot is not a FIT image"

echo "[+] Extracted C20e factory bootchain:"
ls -la "$OUT"
sha256sum "$OUT"/*
echo
echo "[*] U-Boot build string:"
strings "$OUT/c20e-factory-uboot.itb" | grep -m1 -E 'U-Boot 20[0-9]{2}' || true
