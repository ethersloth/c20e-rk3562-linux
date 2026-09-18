#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
DEV="${2:-/dev/sda}"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"
MNT="/mnt/c20e-offline"
BOOT="$MNT/boot"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-analysis/c20e-v5.7r6-offline-$STAMP"
LOG="$REPORT/full.log"

mkdir -p "$REPORT"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    rc=$?
    set +e
    mountpoint -q "$BOOT" && umount "$BOOT"
    mountpoint -q "$MNT" && umount "$MNT"
    rmdir "$MNT" 2>/dev/null || true
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$REPORT" "$REPORT.tar.gz" "$REPORT.tar.gz.sha256" 2>/dev/null || true
    fi
    echo "[$(date -Is)] EXIT rc=$rc"
    exit "$rc"
}
trap cleanup EXIT

die(){ echo "ERROR: $*" >&2; exit 1; }

echo "=== C20e V5.7r6 offline diagnostics ==="
echo "Time:      $(date -Is)"
echo "Repo:      $REPO"
echo "SD target: $DEV"

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "$DEV" && -b "$ROOTDEV" && -b "$BOOTDEV" ]] || die "Expected $DEV with partitions 3 and 4."

for cmd in lsblk blkid blockdev e2fsck fsck.vfat mount umount journalctl tar sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
done

BASE="$(basename "$DEV")"
[[ "$BASE" != nvme* && "$BASE" != mmcblk* ]] || die "Refusing $DEV; expected external USB SD reader."

SIZE="$(blockdev --getsize64 "$DEV")"
(( SIZE >= 30000000000 && SIZE <= 33000000000 )) || die "$DEV size $SIZE bytes is not the expected 32 GB-class card."

MODEL="$(lsblk -dn -o MODEL "$DEV" | xargs || true)"
[[ "$MODEL" == "Storage Device" ]] || die "$DEV model is '$MODEL', expected 'Storage Device'."

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOTDEV" 2>/dev/null || true)"
[[ "$ROOT_PARTUUID" == "c0ffee11-2233-4455-6677-8899aabbccdd" ]] || die "Unexpected root PARTUUID '$ROOT_PARTUUID'."

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$DEV"
    die "Target card has mounted partitions. Unmount them and rerun."
fi

echo
echo "===== 1/8 device snapshot ====="
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL "$DEV" | tee "$REPORT/lsblk.txt"
blkid "$ROOTDEV" "$BOOTDEV" | tee "$REPORT/blkid.txt"

echo
echo "===== 2/8 repair filesystems after hard power-off ====="
set +e
e2fsck -f -y "$ROOTDEV" | tee "$REPORT/e2fsck-rootfs.txt"
E2RC=${PIPESTATUS[0]}
set -e
case "$E2RC" in 0|1|2) ;; *) die "e2fsck failed rc=$E2RC" ;; esac

set +e
fsck.vfat -a "$BOOTDEV" | tee "$REPORT/fsck-boot.txt"
VFRC=${PIPESTATUS[0]}
set -e
case "$VFRC" in 0|1) ;; *) die "fsck.vfat failed rc=$VFRC" ;; esac

echo
echo "===== 3/8 mount card read-only ====="
mkdir -p "$MNT"
mount -o ro "$ROOTDEV" "$MNT"
mkdir -p "$BOOT"
mount -o ro "$BOOTDEV" "$BOOT"

cat "$MNT/etc/hostname" 2>/dev/null | tee "$REPORT/hostname.txt" || true
cat "$BOOT/extlinux/extlinux.conf" > "$REPORT/extlinux.conf" 2>/dev/null || true
cat "$MNT/etc/fstab" > "$REPORT/fstab.txt" 2>/dev/null || true

echo
echo "===== 4/8 journal inventory ====="
JDIR="$MNT/var/log/journal"
if [[ -d "$JDIR" ]]; then
    journalctl --directory="$JDIR" --list-boots --no-pager | tee "$REPORT/journal-boots.txt" || true
    journalctl --directory="$JDIR" -b 0 --no-pager -o short-monotonic > "$REPORT/journal-boot0.txt" 2>&1 || true
    journalctl --directory="$JDIR" -b -1 --no-pager -o short-monotonic > "$REPORT/journal-boot-1.txt" 2>&1 || true
    journalctl --directory="$JDIR" -b 0 -k --no-pager -o short-monotonic > "$REPORT/kernel-boot0.txt" 2>&1 || true
    journalctl --directory="$JDIR" -b -1 -k --no-pager -o short-monotonic > "$REPORT/kernel-boot-1.txt" 2>&1 || true
    journalctl --directory="$JDIR" -b 0 -u lightdm.service -u c20e-usb-debug.service -u serial-getty@ttyGS0.service -u NetworkManager.service -u systemd-udevd.service --no-pager -o short-monotonic > "$REPORT/services-boot0.txt" 2>&1 || true
    grep -Eai 'oops|panic|bug:|unable to handle|segfault|hung task|rcu|watchdog|soft lockup|hard lockup|call trace|skw|seekwave|sv6160|sdio|ff890000|mmc|wlan|firmware|lightdm|xorg|drm|panfrost|gpu|usb|ttygs|acm|dwc3|oom|kstrtoint' "$REPORT/journal-boot0.txt" > "$REPORT/boot0-interesting.txt" || true
    grep -Eai 'oops|panic|bug:|unable to handle|segfault|hung task|rcu|watchdog|soft lockup|hard lockup|call trace|skw|seekwave|sv6160|sdio|ff890000|mmc|wlan|firmware|lightdm|xorg|drm|panfrost|gpu|usb|ttygs|acm|dwc3|oom|kstrtoint' "$REPORT/journal-boot-1.txt" > "$REPORT/boot-1-interesting.txt" || true
else
    echo "No persistent journal directory found at $JDIR" | tee "$REPORT/no-journal.txt"
fi

echo
echo "===== 5/8 display/login/USB logs ====="
for p in "$MNT/var/log/lightdm" "$MNT/var/log/Xorg.0.log" "$MNT/var/log/Xorg.0.log.old" "$MNT/var/lib/systemd/pstore" "$MNT/var/lib/pstore" "$MNT/var/crash"; do
    [[ -e "$p" ]] && cp -a "$p" "$REPORT/" 2>/dev/null || true
done
find "$MNT/var/log" -maxdepth 2 -type f \( -iname '*lightdm*' -o -iname 'Xorg*.log*' -o -iname '*gpu*' \) -print > "$REPORT/display-log-files.txt" 2>/dev/null || true

echo
echo "===== 6/8 Seekwave deployment state ====="
find "$MNT/etc/modules-load.d" -maxdepth 1 -type f -print -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; > "$REPORT/modules-load.txt" 2>/dev/null || true
find "$MNT/etc/modprobe.d" -maxdepth 1 -type f -print -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; > "$REPORT/modprobe.txt" 2>/dev/null || true
find "$MNT/lib/modules/6.1.172" -type f \( -name 'skw*.ko*' -o -name 'swt*.ko*' \) -printf '%p %s bytes\n' | sort > "$REPORT/seekwave-modules.txt" 2>/dev/null || true
find "$MNT/lib/firmware/seekwave" -maxdepth 1 -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum > "$REPORT/seekwave-firmware.sha256" 2>/dev/null || true

echo
echo "===== 7/8 boot image and service state ====="
sha256sum "$BOOT/Image" "$BOOT/rk3562.dtb" > "$REPORT/boot-hashes.txt" 2>/dev/null || true
readlink "$MNT/etc/systemd/system/default.target" > "$REPORT/default-target.txt" 2>/dev/null || true
find "$MNT/etc/systemd/system" -maxdepth 3 -type l \( -name 'c20e-usb-debug.service' -o -name 'serial-getty@ttyGS0.service' -o -name 'lightdm.service' -o -name 'bluetooth.service' \) -printf '%p -> %l\n' > "$REPORT/systemd-links.txt" 2>/dev/null || true

echo
echo "===== 8/8 package report ====="
umount "$BOOT"
umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

tar -C "$REPO/c20e-analysis" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" | tee "$REPORT.tar.gz.sha256"

if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$REPORT" "$REPORT.tar.gz" "$REPORT.tar.gz.sha256"
fi

trap - EXIT
echo
echo "PASS: offline diagnostics collected."
echo "Report: $REPORT.tar.gz"
echo "SHA256: $REPORT.tar.gz.sha256"
echo "The SD filesystems are unmounted."
