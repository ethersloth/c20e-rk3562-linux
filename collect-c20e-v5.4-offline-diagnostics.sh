#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_BASE="${PWD}/c20e-analysis"
OUT="${OUT_BASE}/c20e-v5.4-offline-${STAMP}"
ARCHIVE="${OUT}.tar.gz"
ROOTMNT="/mnt/c20e-v5.4-root-$$"
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

echo "=== C20e V5.4 offline diagnostics ==="
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Target: $DEV"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this script with sudo."
    exit 1
fi

if [[ ! -b "$DEV" ]]; then
    echo "ERROR: $DEV is not a block device."
    exit 1
fi

BASE="$(basename "$DEV")"
if [[ "$BASE" == nvme* || "$BASE" == mmcblk* ]]; then
    echo "ERROR: refusing target $DEV; expected the USB SD reader."
    exit 1
fi

ROOTPART="${DEV}4"
BOOTPART="${DEV}3"

if [[ ! -b "$ROOTPART" || ! -b "$BOOTPART" ]]; then
    echo "ERROR: expected $BOOTPART and $ROOTPART."
    exit 1
fi

SIZE="$(blockdev --getsize64 "$DEV")"
if (( SIZE < 30000000000 || SIZE > 33000000000 )); then
    echo "ERROR: target size is $SIZE bytes; expected the 32 GB-class C20e SD card."
    exit 1
fi

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    echo "ERROR: at least one target partition is mounted. Unmount it before running this collector."
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$DEV"
    exit 1
fi

echo
echo "=== Device identity ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL "$DEV" | tee "$OUT/lsblk.txt"
blkid "$DEV" "$BOOTPART" "$ROOTPART" | tee "$OUT/blkid.txt" || true
fdisk -l "$DEV" > "$OUT/fdisk.txt" 2>&1 || true
udevadm info --query=property --name="$DEV" > "$OUT/udev-device.txt" 2>&1 || true
dumpe2fs -h "$ROOTPART" > "$OUT/ext4-superblock.txt" 2>&1 || true

echo
echo "=== Mounting rootfs read-only with journal replay disabled ==="
mount -t ext4 -o ro,noload "$ROOTPART" "$ROOTMNT"
mkdir -p "$BOOTMNT"
mount -t vfat -o ro "$BOOTPART" "$BOOTMNT"

echo "Root mount:"
findmnt "$ROOTMNT" | tee "$OUT/findmnt-root.txt"
echo "Boot mount:"
findmnt "$BOOTMNT" | tee "$OUT/findmnt-boot.txt"

echo
echo "=== Boot files and hashes ==="
sha256sum "$BOOTMNT/Image" "$BOOTMNT/rk3562.dtb" > "$OUT/boot-hashes.txt" 2>&1 || true
cp -a "$BOOTMNT/extlinux" "$OUT/" 2>/dev/null || true
cp -a "$ROOTMNT/etc/fstab" "$OUT/fstab.txt" 2>/dev/null || true
cp -a "$ROOTMNT/etc/os-release" "$OUT/os-release.txt" 2>/dev/null || true
cp -a "$ROOTMNT/etc/machine-id" "$OUT/machine-id.txt" 2>/dev/null || true

echo
echo "=== C20e scripts/services ==="
for f in \
    "$ROOTMNT/usr/local/sbin/c20e-usb-debug" \
    "$ROOTMNT/usr/local/sbin/c20e-firstboot" \
    "$ROOTMNT/etc/systemd/system/c20e-usb-debug.service" \
    "$ROOTMNT/etc/systemd/system/c20e-firstboot.service"; do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$OUT/$(basename "$f")"
    fi
done
find "$ROOTMNT/etc/systemd/system" -maxdepth 3 -type l \( -name 'c20e-firstboot.service' -o -name 'c20e-usb-debug.service' -o -name 'serial-getty@ttyGS0.service' \) -printf '%p -> %l\n' > "$OUT/systemd-enable-links.txt" 2>/dev/null || true

echo
echo "=== Saved pstore / crash material ==="
mkdir -p "$OUT/pstore"
for d in "$ROOTMNT/var/lib/systemd/pstore" "$ROOTMNT/var/lib/pstore" "$ROOTMNT/var/crash" "$ROOTMNT/var/lib/systemd/coredump"; do
    if [[ -d "$d" ]]; then
        cp -a "$d" "$OUT/pstore/" 2>/dev/null || true
    fi
done
find "$OUT/pstore" -type f -maxdepth 5 -print -exec sh -c 'echo "----- {} -----"; sed -n "1,240p" "{}" 2>/dev/null || true' \; > "$OUT/pstore-summary.txt" 2>&1 || true

echo
echo "=== Persistent journal ==="
JROOT="$ROOTMNT/var/log/journal"
JDIR=""
if [[ -d "$JROOT" ]]; then
    JDIR="$(find "$JROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
fi

if [[ -n "$JDIR" && -d "$JDIR" ]]; then
    echo "Journal directory: $JDIR"
    journalctl --directory="$JDIR" --list-boots --no-pager > "$OUT/journal-boots.txt" 2>&1 || true
    cat "$OUT/journal-boots.txt"

    BOOT_ID="$(journalctl --directory="$JDIR" --list-boots --no-pager 2>/dev/null | tail -n 1 | awk '{print $2}')"
    echo "Selected latest boot ID: ${BOOT_ID:-none}" | tee "$OUT/selected-boot.txt"

    if [[ -n "$BOOT_ID" ]]; then
        journalctl --directory="$JDIR" -b "$BOOT_ID" --no-pager -o short-monotonic > "$OUT/journal-latest-boot.txt" 2>&1 || true
        journalctl --directory="$JDIR" -k -b "$BOOT_ID" --no-pager -o short-monotonic > "$OUT/kernel-latest-boot.txt" 2>&1 || true
        journalctl --directory="$JDIR" -b "$BOOT_ID" --no-pager -o short-monotonic \
            -u c20e-firstboot.service \
            -u c20e-usb-debug.service \
            -u 'serial-getty@ttyGS0.service' > "$OUT/c20e-services-latest-boot.txt" 2>&1 || true

        grep -Eai 'panic|oops|BUG:|watchdog|hung task|soft lockup|hard lockup|rcu.*stall|segfault|general protection|unable to handle|page fault|corrupt|I/O error|mmc|sdio|seekwave|skw|usb|dwc3|ttyGS|gserial|cdc|acm|firstboot|journald|gc02m1|gc02m2|ov5648|dw9714|husb320|typec|drm|panfrost|deferred probe' \
            "$OUT/journal-latest-boot.txt" > "$OUT/journal-interesting.txt" 2>/dev/null || true

        awk 'match($0,/^\[[[:space:]]*([0-9]+\.[0-9]+)\]/,m){t=m[1]+0;if(t>=240 && t<=360)print}' \
            "$OUT/journal-latest-boot.txt" > "$OUT/journal-240-360s.txt" 2>/dev/null || true

        tail -n 600 "$OUT/journal-latest-boot.txt" > "$OUT/journal-last-600-lines.txt" 2>/dev/null || true
    fi
else
    echo "No persistent journal directory found." | tee "$OUT/journal-status.txt"
fi

echo
echo "=== Traditional logs / shutdown history ==="
for f in "$ROOTMNT/var/log/syslog" "$ROOTMNT/var/log/kern.log" "$ROOTMNT/var/log/boot.log"; do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$OUT/$(basename "$f")"
    fi
done
if [[ -f "$ROOTMNT/var/log/wtmp" ]]; then
    last -x -f "$ROOTMNT/var/log/wtmp" > "$OUT/last-x.txt" 2>&1 || true
fi

echo
echo "=== Filesystem state after hard power-off ==="
tune2fs -l "$ROOTPART" > "$OUT/tune2fs.txt" 2>&1 || true
grep -E 'Filesystem state|Errors behavior|Last mount time|Last write time|Mount count|Last checked|Lifetime writes' "$OUT/tune2fs.txt" || true

echo
echo "=== Unmounting read-only mounts ==="
umount "$BOOTMNT"
umount "$ROOTMNT"
rmdir "$ROOTMNT" 2>/dev/null || true
trap - EXIT

echo
echo "=== Packaging report ==="
tar -C "$OUT_BASE" -czf "$ARCHIVE" "$(basename "$OUT")"
sha256sum "$ARCHIVE" | tee "${ARCHIVE}.sha256"

echo
echo "DONE"
echo "Report: $ARCHIVE"
echo "SHA256: ${ARCHIVE}.sha256"
echo "The SD card was only mounted read-only; ext4 journal replay was disabled."
