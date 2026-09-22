#!/usr/bin/env bash
set -u
ROOT="${1:-/mnt}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${PWD}/c20e-v4-freeze-${STAMP}"
ARCHIVE="${OUT}.tar.gz"
mkdir -p "$OUT"
LOG="$OUT/collector.log"
exec > >(tee -a "$LOG") 2>&1
echo "C20e V4 freeze diagnostics: $(date -Is)"
echo "Rootfs: $ROOT"
[ -f "$ROOT/etc/os-release" ] || { echo "ERROR: $ROOT is not a mounted Linux rootfs"; exit 1; }
cp -a "$ROOT/etc/os-release" "$OUT/os-release" 2>/dev/null || true
cp -a "$ROOT/etc/fstab" "$OUT/fstab" 2>/dev/null || true
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$OUT/deployed-boot-sha256.txt" 2>&1 || true
[ -f "$ROOT/boot/Image.pre-husb320" ] && sha256sum "$ROOT/boot/Image.pre-husb320" >>"$OUT/deployed-boot-sha256.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" --list-boots >"$OUT/journal-boots.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b 0 --no-pager -o short-monotonic >"$OUT/journal-current-boot.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b 0 -k --no-pager -o short-monotonic >"$OUT/kernel-current-boot.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b -1 --no-pager -o short-monotonic >"$OUT/journal-previous-boot.txt" 2>&1 || true
journalctl --directory="$ROOT/var/log/journal" -b -1 -k --no-pager -o short-monotonic >"$OUT/kernel-previous-boot.txt" 2>&1 || true
grep -Eai 'oops|panic|bug:|unable to handle|null pointer|call trace|pc :|lr :|corrupt|segfault|watchdog|hung task|rcu|mmc|sdhci|i/o error|ext4|dwc3|usb|husb|typec|panfrost|mali|drm|seek|skw|wlan|wifi|ov5648|gc02m1|dw9714|camera|csi|isp|defer|sc7a20|mir3da|da223' "$OUT/kernel-current-boot.txt" >"$OUT/kernel-current-targeted.txt" 2>/dev/null || true
grep -Eai 'oops|panic|bug:|unable to handle|null pointer|call trace|pc :|lr :|corrupt|segfault|watchdog|hung task|rcu|mmc|sdhci|i/o error|ext4|dwc3|usb|husb|typec|panfrost|mali|drm|seek|skw|wlan|wifi|ov5648|gc02m1|dw9714|camera|csi|isp|defer|sc7a20|mir3da|da223' "$OUT/kernel-previous-boot.txt" >"$OUT/kernel-previous-targeted.txt" 2>/dev/null || true
find "$ROOT/sys/fs/pstore" "$ROOT/var/lib/systemd/pstore" -maxdepth 2 -type f -print -exec cp -a '{}' "$OUT/" ';' >"$OUT/pstore-files.txt" 2>&1 || true
find "$ROOT/var/log" -maxdepth 2 -type f \( -name 'kern.log*' -o -name 'syslog*' -o -name 'messages*' \) -print >"$OUT/classic-log-files.txt" 2>&1 || true
systemd-analyze --root="$ROOT" verify "$ROOT/etc/systemd/system/c20e-usb-debug.service" >"$OUT/c20e-usb-debug-verify.txt" 2>&1 || true
find "$ROOT/etc/systemd/system" -maxdepth 3 -type l -o -type f | sort >"$OUT/systemd-local-files.txt" 2>&1 || true
sync
tar -C "$(dirname "$OUT")" -czf "$ARCHIVE" "$(basename "$OUT")"
echo
echo "Archive created:"
echo "$ARCHIVE"
echo "SHA256:"
sha256sum "$ARCHIVE"
