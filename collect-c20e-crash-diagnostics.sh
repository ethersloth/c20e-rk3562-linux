#!/bin/bash
set -u

DEV="${1:-/dev/sda}"
ROOT="${2:-/mnt}"
OUT="${3:-$PWD/c20e-diagnostics-$(date +%Y%m%d-%H%M%S)}"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

case "$DEV" in
    /dev/sd?) ;;
    *) echo "ERROR: expected a whole USB/SD device such as /dev/sda." >&2; exit 1 ;;
esac

if [ ! -b "$DEV" ] || [ ! -b "$ROOTDEV" ]; then
    echo "ERROR: $DEV or $ROOTDEV does not exist." >&2
    exit 1
fi

mkdir -p "$OUT"

{
    echo "=== C20e crash diagnostics ==="
    date -Is
    echo
    echo "=== Target device ==="
    lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DEV"
    echo
    echo "=== Partition table ==="
    fdisk -l "$DEV" 2>&1
} > "$OUT/host-device.txt" 2>&1

MOUNTED_BY_SCRIPT=0
if ! mountpoint -q "$ROOT"; then
    mkdir -p "$ROOT"
    mount "$ROOTDEV" "$ROOT" || { echo "ERROR: could not mount $ROOTDEV at $ROOT"; exit 1; }
    MOUNTED_BY_SCRIPT=1
fi

{
    echo "=== Root filesystem ==="
    findmnt "$ROOT"
    echo
    echo "=== OS release ==="
    cat "$ROOT/etc/os-release" 2>/dev/null || true
    echo
    echo "=== Installed kernel files ==="
    ls -lh "$ROOT/boot" 2>/dev/null || true
} > "$OUT/rootfs-info.txt" 2>&1

mkdir -p "$OUT/pstore"
for d in "$ROOT/sys/fs/pstore" "$ROOT/var/lib/systemd/pstore" "$ROOT/var/lib/pstore"; do
    if [ -d "$d" ]; then
        find "$d" -maxdepth 2 -type f -print -exec cp -a --parents '{}' "$OUT/pstore/" \; 2>/dev/null || true
    fi
done

journalctl --directory="$ROOT/var/log/journal" --list-boots --no-pager > "$OUT/journal-boots.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b 0 -k --no-pager > "$OUT/kernel-journal-current.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b -1 -k --no-pager > "$OUT/kernel-journal-previous.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b 0 --no-pager > "$OUT/full-journal-current.txt" 2>&1 || true

grep -Eai 'panic|oops|BUG:|Unable to handle|Call trace|pc :|lr :|end trace|watchdog|hung task|segfault|husb|typec|role.switch|dwc3|fe500000|ff740000|ttyGS|configfs|gadget|seekw|skw|mmc|panfrost|drm|camera|ov5648|gc02m1' "$OUT/kernel-journal-current.txt" > "$OUT/kernel-important.txt" 2>/dev/null || true

{
    echo "=== USB debug files ==="
    ls -l "$ROOT/etc/systemd/system/c20e-usb-debug.service" "$ROOT/usr/local/sbin/c20e-usb-debug" 2>&1 || true
    echo
    echo "=== USB role manager enablement ==="
    systemctl --root="$ROOT" is-enabled usb-role-manager.service 2>&1 || true
    echo
    echo "=== USB debug enablement ==="
    systemctl --root="$ROOT" is-enabled c20e-usb-debug.service 2>&1 || true
    echo
    echo "=== ttyGS0 getty enablement ==="
    systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service 2>&1 || true
    echo
    echo "=== USB debug log ==="
    cat "$ROOT/var/log/c20e-usb-debug.log" 2>/dev/null || true
} > "$OUT/usb-debug.txt" 2>&1

dmesg > "$OUT/fedora-dmesg.txt" 2>&1 || true

tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"

if [ "$MOUNTED_BY_SCRIPT" -eq 1 ]; then
    sync
    umount "$ROOT"
fi

echo
echo "Diagnostics complete."
echo "Folder:  $OUT"
echo "Archive: $OUT.tar.gz"
echo
echo "The script did NOT modify the tablet kernel, DTB, bootloader, or internal eMMC."
echo "It did NOT power off/eject $DEV."
