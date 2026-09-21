#!/bin/bash
# Back up the C20e internal eMMC, everything except userdata.  READ-ONLY.
# Run ON THE TABLET with sudo.
#
# Covers GPT, bootloader (uboot_a/b, trust_a/b), boot/init_boot/vendor_boot/
# dtbo/vbmeta A+B, misc, resource, frp, baseparameter, metadata, cache and the
# Android `super` partition -- a fully restorable Android. userdata (52 GiB of
# user content) is skipped and comes back as a factory reset.
#
# The end sector is read from the live partition table, not hard-coded, and
# the read is done in whole SECTORS. An earlier version computed a byte count
# as END*512/1024/1024 MiB; 11746304*512 bytes is 5735.5 MiB, integer division
# floored it to 5735, and the final 512 KiB before userdata was silently never
# read. (That region turned out to be unused, all zeros: Android's liblp keeps
# BOTH primary and backup dynamic-partition metadata near the START of `super`,
# not the end. So that particular truncation was harmless -- but a backup whose
# size is not checked cannot be trusted, which is why this one is.)
set -euo pipefail

DEV=/dev/mmcblk2
OUT="${1:-/var/tmp/c20e-emmc-preinstall.img.zst}"

[ -b "$DEV" ] || { echo "no $DEV"; exit 1; }
UD="$(lsblk -nro NAME,PARTLABEL "$DEV" | awk '$2=="userdata"{print $1}')"
[ -n "$UD" ] || { echo "no userdata partition found on $DEV"; exit 1; }
END=$(cat /sys/block/$(basename "$DEV")/$UD/start)
echo "backing up $DEV sectors 0..$END (everything before $UD/userdata)"

# bs=512 + count in SECTORS: exact, no rounding anywhere.
dd if="$DEV" bs=512 count="$END" iflag=fullblock status=progress conv=noerror \
  | zstd -T0 -3 -f -o "$OUT"

GOT=$(zstd -dc "$OUT" | wc -c)
WANT=$((END * 512))
echo "decompressed $GOT bytes, expected $WANT"
[ "$GOT" -eq "$WANT" ] || { echo "*** SIZE MISMATCH -- backup incomplete ***"; exit 1; }
sfdisk -d "$DEV" > "${OUT%.img.zst}-gpt.sfdisk"
sha256sum "$OUT"
echo "OK: complete. Nothing was written to $DEV."
