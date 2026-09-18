#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
DEV="${2:-/dev/sda}"
ROOT="${3:-/mnt}"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"

K="$REPO/src/kernel"
IMG="$K/arch/arm64/boot/Image"
USB_SCRIPT="$ROOT/usr/local/sbin/c20e-usb-debug"
USB_SERVICE="$ROOT/etc/systemd/system/c20e-usb-debug.service"
FIRSTBOOT_SCRIPT="$ROOT/usr/local/sbin/c20e-firstboot"
FIRSTBOOT_SERVICE="$ROOT/etc/systemd/system/c20e-firstboot.service"
INSTALLER="$REPO/install-c20e-usb-debug.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-v5.5-serial-firstboot-$STAMP"
mkdir -p "$REPORT/backups"
exec > >(tee -a "$REPORT/full.log") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }

cleanup(){
    rc=$?
    set +e
    mountpoint -q "$ROOT/boot" && umount "$ROOT/boot"
    mountpoint -q "$ROOT" && umount "$ROOT"
    echo "[$(date -Is)] EXIT rc=$rc"
    exit "$rc"
}
trap cleanup EXIT

echo "C20e V5.5 serial-firstboot stability integration: $(date -Is)"
echo "Repo:   $REPO"
echo "Device: $DEV"
echo "Root:   $ROOTDEV"
echo "Boot:   $BOOTDEV"

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -d "$K" ]] || die "kernel tree missing: $K"
[[ -f "$K/.config" ]] || die "kernel .config missing"
[[ -s "$IMG" ]] || die "current built Image missing"
[[ -b "$DEV" && -b "$ROOTDEV" && -b "$BOOTDEV" ]] || die "expected $DEV with partitions 3 and 4"

BASE="$(basename "$DEV")"
[[ "$BASE" != nvme* && "$BASE" != mmcblk* ]] || die "refusing $DEV; expected USB SD reader"

SIZE="$(blockdev --getsize64 "$DEV")"
(( SIZE >= 30000000000 && SIZE <= 33000000000 )) || die "$DEV size $SIZE bytes is not the expected 32 GB-class card"

MODEL="$(lsblk -dn -o MODEL "$DEV" | xargs || true)"
[[ "$MODEL" == "Storage Device" ]] || die "$DEV model is '$MODEL', expected 'Storage Device'"

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    die "one or more $DEV partitions are already mounted"
fi

echo
echo "===== 1/9 repair filesystems after forced power-off ====="
set +e
e2fsck -f -y "$ROOTDEV" | tee "$REPORT/e2fsck-rootfs.txt"
E2RC=${PIPESTATUS[0]}
set -e
case "$E2RC" in
    0|1|2) ;;
    *) die "e2fsck failed with rc=$E2RC" ;;
esac

if command -v fsck.vfat >/dev/null 2>&1; then
    set +e
    fsck.vfat -a "$BOOTDEV" | tee "$REPORT/fsck-boot.txt"
    VFRC=${PIPESTATUS[0]}
    set -e
    case "$VFRC" in
        0|1) ;;
        *) die "fsck.vfat failed with rc=$VFRC" ;;
    esac
else
    echo "NOTE: fsck.vfat not installed; boot VFAT check skipped." | tee "$REPORT/fsck-boot.txt"
fi

echo
echo "===== 2/9 mount verified rootfs and real boot partition ====="
mkdir -p "$ROOT"
mount "$ROOTDEV" "$ROOT"
mkdir -p "$ROOT/boot"
mount "$BOOTDEV" "$ROOT/boot"

[[ "$(findmnt -n -o SOURCE --target "$ROOT")" == "$ROOTDEV" ]] || die "root mount mismatch"
[[ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" == "$BOOTDEV" ]] || die "boot mount mismatch"

[[ -f "$USB_SCRIPT" ]] || die "installed c20e-usb-debug missing"
[[ -f "$USB_SERVICE" ]] || die "installed c20e-usb-debug.service missing"
[[ -f "$FIRSTBOOT_SCRIPT" ]] || die "installed c20e-firstboot missing"
[[ -f "$FIRSTBOOT_SERVICE" ]] || die "installed c20e-firstboot.service missing"
[[ -s "$ROOT/boot/Image" ]] || die "actual boot Image missing"

cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image does not match current V5.4 built Image"

cp -a "$K/.config" "$REPORT/backups/config.before-v5.5"
cp -a "$ROOT/boot/Image" "$REPORT/backups/Image.actual-boot.before-v5.5"
cp -a "$USB_SCRIPT" "$REPORT/backups/c20e-usb-debug.before-v5.5"
cp -a "$USB_SERVICE" "$REPORT/backups/c20e-usb-debug.service.before-v5.5"
cp -a "$FIRSTBOOT_SCRIPT" "$REPORT/backups/c20e-firstboot.before-v5.5"
cp -a "$FIRSTBOOT_SERVICE" "$REPORT/backups/c20e-firstboot.service.before-v5.5"
[[ ! -f "$INSTALLER" ]] || cp -a "$INSTALLER" "$REPORT/backups/install-c20e-usb-debug.before-v5.5"

sha256sum "$IMG" "$ROOT/boot/Image" >"$REPORT/image-before.sha256"

echo
echo "===== 3/9 quarantine corrupt chaos user journal ====="
MACHINE_ID="$(cat "$ROOT/etc/machine-id" 2>/dev/null || true)"
JDIR="$ROOT/var/log/journal/$MACHINE_ID"
QDIR="$ROOT/var/lib/c20e/quarantine"
mkdir -p "$QDIR"

if [[ -n "$MACHINE_ID" && -f "$JDIR/user-1000.journal" ]]; then
    cp -a "$JDIR/user-1000.journal" "$REPORT/backups/user-1000.journal.v5.4"
    mv "$JDIR/user-1000.journal" "$QDIR/user-1000.journal.v5.4-corrupt-$STAMP"
    echo "Quarantined user-1000.journal."
else
    echo "No user-1000.journal found to quarantine."
fi

echo
echo "===== 4/9 disable ttyGS kernel printk console for A/B stability test ====="
"$K/scripts/config" --file "$K/.config" --disable U_SERIAL_CONSOLE

CROSS="$(command -v aarch64-linux-gnu-gcc || true)"
[[ -n "$CROSS" ]] || die "aarch64-linux-gnu-gcc not found"
CROSS="${CROSS%gcc}"
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"

make -C "$K" olddefconfig

grep -q '^# CONFIG_U_SERIAL_CONSOLE is not set' "$K/.config" || die "U_SERIAL_CONSOLE did not disable"
grep -q '^CONFIG_USB_GADGET=y' "$K/.config" || die "USB gadget support lost"
grep -q '^CONFIG_USB_U_SERIAL=y' "$K/.config" || die "USB u_serial support lost"
grep -q '^CONFIG_USB_CONFIGFS=y' "$K/.config" || die "USB ConfigFS support lost"
grep -q '^CONFIG_USB_CONFIGFS_ACM=y' "$K/.config" || die "USB ConfigFS ACM support lost"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost drifted"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost drifted"
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 drifted"
grep -q '^CONFIG_VIDEO_GC02M1=y' "$K/.config" || die "GC02M1 drifted"
grep -q '^CONFIG_VIDEO_OV5648=y' "$K/.config" || die "OV5648 drifted"
grep -q '^CONFIG_VIDEO_DW9714=y' "$K/.config" || die "DW9714 drifted"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "dynamic ftrace unexpectedly enabled"

echo
echo "===== 5/9 return ACM gadget to plain ttyGS0 mode ====="
python3 - "$USB_SCRIPT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
tag = '# c20e-v5.4-usb-kernel-console'
if tag in t:
    start = t.index(tag)
    line_start = t.rfind('\n', 0, start) + 1
    anchor = 'ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"'
    end = t.find(anchor, start)
    if end < 0:
        raise SystemExit('could not locate ACM symlink after V5.4 console block')
    t = t[:line_start] + t[end:]
p.write_text(t)
PY
chmod 0755 "$USB_SCRIPT"

grep -q 'functions/acm.usb0/console' "$USB_SCRIPT" && die "installed USB script still enables ACM kernel console"
grep -q '# c20e-v5.4-usb-kernel-console' "$USB_SCRIPT" && die "installed V5.4 console marker still present"

python3 - "$USB_SERVICE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
lines = [x for x in lines if 'ExecStartPost=/bin/systemctl start serial-getty@ttyGS0.service' not in x]
p.write_text('\n'.join(lines).rstrip() + '\n')
PY

grep -q 'ExecStartPost=.*serial-getty@ttyGS0' "$USB_SERVICE" && die "USB service still starts ttyGS0 getty"

if [[ -f "$INSTALLER" ]]; then
    python3 - "$INSTALLER" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
tag = '# c20e-v5.4-usb-kernel-console'
while tag in t:
    start = t.index(tag)
    line_start = t.rfind('\n', 0, start) + 1
    anchor = 'ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"'
    end = t.find(anchor, start)
    if end < 0:
        raise SystemExit('could not locate ACM symlink after V5.4 block in installer')
    t = t[:line_start] + t[end:]
t = '\n'.join(
    line for line in t.splitlines()
    if 'ExecStartPost=/bin/systemctl start serial-getty@ttyGS0.service' not in line
) + '\n'
p.write_text(t)
PY
    chmod 0755 "$INSTALLER"
fi

echo
echo "===== 6/9 move first-boot wizard to USB ttyGS0 ====="
cat >"$FIRSTBOOT_SERVICE" <<'EOF'
[Unit]
Description=C20e first-boot account setup over USB serial
Requires=c20e-usb-debug.service
After=local-fs.target systemd-user-sessions.service c20e-usb-debug.service
Before=serial-getty@ttyGS0.service
Conflicts=serial-getty@ttyGS0.service
ConditionPathExists=!/var/lib/c20e/firstboot-complete

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-firstboot
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyGS0
TTYReset=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl --root="$ROOT" disable serial-getty@ttyGS0.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null
systemctl --root="$ROOT" enable c20e-firstboot.service >/dev/null

[[ ! -e "$ROOT/var/lib/c20e/firstboot-complete" ]] || die "firstboot is already marked complete unexpectedly"

grep -q '^TTYPath=/dev/ttyGS0$' "$FIRSTBOOT_SERVICE" || die "firstboot is not attached to ttyGS0"
grep -q '^StandardInput=tty-force$' "$FIRSTBOOT_SERVICE" || die "firstboot tty-force input missing"
grep -q '^Conflicts=serial-getty@ttyGS0.service$' "$FIRSTBOOT_SERVICE" || die "firstboot/getty conflict guard missing"

echo
echo "===== 7/9 rebuild and deploy kernel Image ====="
make -C "$K" -j"$(nproc)" Image

[[ -s "$IMG" ]] || die "rebuilt Image missing"
grep -q '^# CONFIG_U_SERIAL_CONSOLE is not set' "$K/.config" || die "U_SERIAL_CONSOLE changed during build"

sha256sum "$IMG" >"$REPORT/build-image.sha256"
install -m 0644 "$IMG" "$ROOT/boot/Image"
sync

cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image byte mismatch"
sha256sum "$ROOT/boot/Image" >"$REPORT/actual-boot-image.sha256"

echo
echo "===== 8/9 final validation and report ====="
cp -a "$K/.config" "$REPORT/config-used"
cp -a "$USB_SCRIPT" "$REPORT/c20e-usb-debug.final"
cp -a "$USB_SERVICE" "$REPORT/c20e-usb-debug.service.final"
cp -a "$FIRSTBOOT_SCRIPT" "$REPORT/c20e-firstboot.final"
cp -a "$FIRSTBOOT_SERVICE" "$REPORT/c20e-firstboot.service.final"
cp -a "$ROOT/boot/extlinux/extlinux.conf" "$REPORT/extlinux.conf"
[[ ! -f "$INSTALLER" ]] || cp -a "$INSTALLER" "$REPORT/install-c20e-usb-debug.final"

diff -u "$REPORT/backups/config.before-v5.5" "$K/.config" >"$REPORT/config.diff" || true
diff -u "$REPORT/backups/c20e-usb-debug.before-v5.5" "$USB_SCRIPT" >"$REPORT/c20e-usb-debug.diff" || true
diff -u "$REPORT/backups/c20e-usb-debug.service.before-v5.5" "$USB_SERVICE" >"$REPORT/c20e-usb-debug.service.diff" || true
diff -u "$REPORT/backups/c20e-firstboot.service.before-v5.5" "$FIRSTBOOT_SERVICE" >"$REPORT/c20e-firstboot.service.diff" || true
if [[ -f "$REPORT/backups/install-c20e-usb-debug.before-v5.5" && -f "$INSTALLER" ]]; then
    diff -u "$REPORT/backups/install-c20e-usb-debug.before-v5.5" "$INSTALLER" >"$REPORT/installer.diff" || true
fi

grep -E '^(CONFIG_U_SERIAL_CONSOLE=|# CONFIG_U_SERIAL_CONSOLE|CONFIG_USB_GADGET=|CONFIG_USB_U_SERIAL=|CONFIG_USB_CONFIGFS=|CONFIG_USB_CONFIGFS_ACM=|CONFIG_DRM_PANFROST=|# CONFIG_MALI_BIFROST|CONFIG_TYPEC_HUSB320=|CONFIG_VIDEO_GC02M1=|CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|# CONFIG_DYNAMIC_FTRACE)' "$K/.config" >"$REPORT/protected-config.txt" || true

systemctl --root="$ROOT" is-enabled c20e-usb-debug.service >"$REPORT/usb-debug-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled c20e-firstboot.service >"$REPORT/firstboot-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service >"$REPORT/ttygs0-enabled-before-firstboot.txt" 2>&1 || true

findmnt "$ROOT" >"$REPORT/findmnt-root.txt"
findmnt "$ROOT/boot" >"$REPORT/findmnt-boot.txt"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/boot-hashes.txt" 2>&1 || true

tar -C "$REPO" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" >"$REPORT.tar.gz.sha256"

echo
echo "===== 9/9 sync and safely unmount SD ====="
sync
umount "$ROOT/boot"
umount "$ROOT"
trap - EXIT

echo
echo "PASS: C20e V5.5 serial-firstboot stability integration completed."
echo "Changes:"
echo "  - repaired rootfs after forced shutdown"
echo "  - quarantined corrupt user-1000 journal"
echo "  - disabled CONFIG_U_SERIAL_CONSOLE"
echo "  - restored plain ACM ttyGS0 gadget"
echo "  - firstboot now owns ttyGS0 directly"
echo "  - serial-getty is disabled until firstboot completes"
echo "  - firstboot will enable ttyGS0 getty for later boots and reboot"
echo
echo "Report archive: $REPORT.tar.gz"
echo "Report SHA256:  $REPORT.tar.gz.sha256"
echo "SD partitions are unmounted and ready for review/removal."
echo "Do not boot until the V5.5 report is reviewed."
