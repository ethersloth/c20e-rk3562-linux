#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_BASE="${PWD}/c20e-analysis"
OUT="${OUT_BASE}/c20e-v5.5-post-firstboot-${STAMP}"
ARCHIVE="${OUT}.tar.gz"
ROOTMNT="/mnt/c20e-v5.5-post-$$"
BOOTMNT="${ROOTMNT}/boot"
LOG="${OUT}/collector.log"

mkdir -p "$OUT_BASE" "$OUT" "$ROOTMNT"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    set +e
    mountpoint -q "$BOOTMNT" && umount "$BOOTMNT"
    mountpoint -q "$ROOTMNT" && umount "$ROOTMNT"
    rmdir "$ROOTMNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== C20e V5.5 post-firstboot offline diagnostics ==="
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Target: $DEV"

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo."; exit 1; }
[[ -b "$DEV" ]] || { echo "ERROR: $DEV is not a block device."; exit 1; }

BASE="$(basename "$DEV")"
[[ "$BASE" != nvme* && "$BASE" != mmcblk* ]] || { echo "ERROR: refusing $DEV; expected USB SD reader."; exit 1; }

ROOTPART="${DEV}4"
BOOTPART="${DEV}3"
[[ -b "$ROOTPART" && -b "$BOOTPART" ]] || { echo "ERROR: expected $BOOTPART and $ROOTPART."; exit 1; }

SIZE="$(blockdev --getsize64 "$DEV")"
(( SIZE >= 30000000000 && SIZE <= 33000000000 )) || { echo "ERROR: target size is $SIZE bytes; expected 32 GB-class C20e SD."; exit 1; }

MODEL="$(lsblk -dn -o MODEL "$DEV" | xargs || true)"
[[ "$MODEL" == "Storage Device" ]] || { echo "ERROR: $DEV model is '$MODEL', expected 'Storage Device'."; exit 1; }

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    echo "ERROR: at least one target partition is mounted."
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$DEV"
    exit 1
fi

echo
echo "=== Device identity ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL "$DEV" | tee "$OUT/lsblk.txt"
blkid "$DEV" "$BOOTPART" "$ROOTPART" | tee "$OUT/blkid.txt" || true
fdisk -l "$DEV" >"$OUT/fdisk.txt" 2>&1 || true
dumpe2fs -h "$ROOTPART" >"$OUT/ext4-superblock.txt" 2>&1 || true

echo
echo "=== Mounting read-only, no ext4 journal replay ==="
mount -t ext4 -o ro,noload "$ROOTPART" "$ROOTMNT"
mkdir -p "$BOOTMNT"
mount -t vfat -o ro "$BOOTPART" "$BOOTMNT"
findmnt "$ROOTMNT" | tee "$OUT/findmnt-root.txt"
findmnt "$BOOTMNT" | tee "$OUT/findmnt-boot.txt"

echo
echo "=== Firstboot completion state ==="
{
    echo "--- hostname ---"
    cat "$ROOTMNT/etc/hostname" 2>/dev/null || true
    echo "--- primary user ---"
    cat "$ROOTMNT/var/lib/c20e/primary-user" 2>/dev/null || true
    echo "--- firstboot marker ---"
    ls -l "$ROOTMNT/var/lib/c20e/firstboot-complete" 2>/dev/null || true
    echo "--- default target ---"
    ls -l "$ROOTMNT/etc/systemd/system/default.target" 2>/dev/null || true
    echo "--- account status ---"
    grep -E '^(root|chaos|gwhitlock):' "$ROOTMNT/etc/shadow" 2>/dev/null | sed 's/:[^:]*:/:<redacted>:/' || true
} | tee "$OUT/firstboot-state.txt"

echo
echo "=== Boot configuration ==="
cp -a "$BOOTMNT/extlinux/extlinux.conf" "$OUT/extlinux.conf" 2>/dev/null || true
sha256sum "$BOOTMNT/Image" "$BOOTMNT/rk3562.dtb" >"$OUT/boot-hashes.txt" 2>&1 || true
grep -E '^default |^label |^[[:space:]]+append ' "$BOOTMNT/extlinux/extlinux.conf" >"$OUT/extlinux-summary.txt" 2>/dev/null || true
cat "$OUT/extlinux-summary.txt" 2>/dev/null || true

echo
echo "=== Relevant installed services and scripts ==="
mkdir -p "$OUT/config"
for f in \
    "$ROOTMNT/usr/local/sbin/c20e-usb-debug" \
    "$ROOTMNT/usr/local/sbin/c20e-firstboot" \
    "$ROOTMNT/etc/systemd/system/c20e-usb-debug.service" \
    "$ROOTMNT/etc/systemd/system/c20e-firstboot.service"; do
    [[ -f "$f" ]] && cp -a "$f" "$OUT/config/$(basename "$f")"
done

find "$ROOTMNT/etc/systemd/system" -maxdepth 4 -type l \
    \( -name 'c20e-firstboot.service' -o -name 'c20e-usb-debug.service' -o -name 'serial-getty@ttyGS0.service' -o -name 'lightdm.service' -o -name 'default.target' \) \
    -printf '%p -> %l\n' >"$OUT/systemd-links.txt" 2>/dev/null || true
cat "$OUT/systemd-links.txt" 2>/dev/null || true

echo
echo "=== USB debug / display-manager logs ==="
for f in \
    "$ROOTMNT/var/log/c20e-usb-debug.log" \
    "$ROOTMNT/var/log/Xorg.0.log" \
    "$ROOTMNT/var/log/Xorg.0.log.old"; do
    [[ -f "$f" ]] && cp -a "$f" "$OUT/$(basename "$f")"
done

if [[ -d "$ROOTMNT/var/log/lightdm" ]]; then
    cp -a "$ROOTMNT/var/log/lightdm" "$OUT/lightdm-logs" 2>/dev/null || true
fi

echo
echo "=== Persistent journal: latest two boots ==="
JROOT="$ROOTMNT/var/log/journal"
JDIR=""
[[ -d "$JROOT" ]] && JDIR="$(find "$JROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"

if [[ -n "$JDIR" && -d "$JDIR" ]]; then
    journalctl --directory="$JDIR" --list-boots --no-pager >"$OUT/journal-boots.txt" 2>&1 || true
    cat "$OUT/journal-boots.txt"

    mapfile -t BOOT_IDS < <(journalctl --directory="$JDIR" --list-boots --no-pager 2>/dev/null | tail -n 2 | awk '{print $2}')
    IDX=0
    for BID in "${BOOT_IDS[@]}"; do
        [[ -n "$BID" ]] || continue
        IDX=$((IDX+1))
        PREFIX="$OUT/boot-${IDX}-${BID}"
        echo "Collecting boot $IDX: $BID"
        journalctl --directory="$JDIR" -b "$BID" --no-pager -o short-monotonic >"${PREFIX}-all.txt" 2>&1 || true
        journalctl --directory="$JDIR" -k -b "$BID" --no-pager -o short-monotonic >"${PREFIX}-kernel.txt" 2>&1 || true
        journalctl --directory="$JDIR" -b "$BID" --no-pager -o short-monotonic \
            -u c20e-firstboot.service \
            -u c20e-usb-debug.service \
            -u 'serial-getty@ttyGS0.service' \
            -u lightdm.service \
            -u systemd-user-sessions.service >"${PREFIX}-services.txt" 2>&1 || true
        grep -Eai 'panic|oops|BUG:|watchdog|hung task|soft lockup|hard lockup|rcu.*stall|segfault|unable to handle|page fault|I/O error|mmc|sdio|seekwave|skw|usb|dwc3|ttyGS|gserial|cdc|acm|firstboot|lightdm|Xorg|drm|panfrost|plymouth|journald|gc02m1|ov5648|dw9714|husb320|typec|deferred probe|reboot|shutdown|failed|error' \
            "${PREFIX}-all.txt" >"${PREFIX}-interesting.txt" 2>/dev/null || true
        tail -n 500 "${PREFIX}-all.txt" >"${PREFIX}-last-500.txt" 2>/dev/null || true
    done
else
    echo "No persistent journal directory found." | tee "$OUT/journal-status.txt"
fi

echo
echo "=== Saved pstore/crash material ==="
mkdir -p "$OUT/pstore"
for d in "$ROOTMNT/var/lib/systemd/pstore" "$ROOTMNT/var/lib/pstore" "$ROOTMNT/var/crash"; do
    [[ -d "$d" ]] && cp -a "$d" "$OUT/pstore/" 2>/dev/null || true
done
find "$OUT/pstore" -type f -maxdepth 5 -print >"$OUT/pstore-files.txt" 2>/dev/null || true

echo
echo "=== Root filesystem state ==="
tune2fs -l "$ROOTPART" >"$OUT/tune2fs.txt" 2>&1 || true
grep -E 'Filesystem state|Errors behavior|Last mount time|Last write time|Mount count|Last checked|Lifetime writes|Filesystem features' "$OUT/tune2fs.txt" || true

echo
echo "=== Packaging report ==="
umount "$BOOTMNT"
umount "$ROOTMNT"
rmdir "$ROOTMNT" 2>/dev/null || true
trap - EXIT

tar -C "$OUT_BASE" -czf "$ARCHIVE" "$(basename "$OUT")"
sha256sum "$ARCHIVE" | tee "${ARCHIVE}.sha256"

echo
echo "DONE"
echo "Report: $ARCHIVE"
echo "SHA256: ${ARCHIVE}.sha256"
echo "No filesystem changes were made; rootfs was mounted ro,noload."
