#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
ROOTDEV="${3:-/dev/sda4}"
BOOTDEV="${4:-/dev/sda3}"

K="$REPO/src/kernel"
IMG="$K/arch/arm64/boot/Image"
DEBUG_SCRIPT="$ROOT/usr/local/sbin/c20e-usb-debug"
INSTALLER="$REPO/install-c20e-usb-debug.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-v5.4-usb-console-$STAMP"
mkdir -p "$REPORT/backups"
exec > >(tee -a "$REPORT/full.log") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT

echo "C20e V5.4 USB kernel console integration: $(date -Is)"
echo "Repo:   $REPO"
echo "Rootfs: $ROOT ($ROOTDEV)"
echo "Boot:   $BOOTDEV"

[ -d "$K" ] || die "kernel tree missing"
[ -f "$K/.config" ] || die "kernel .config missing"
[ -s "$IMG" ] || die "current built Image missing"
[ -f "$DEBUG_SCRIPT" ] || die "installed c20e-usb-debug missing"
[ -d "$ROOT/etc" ] || die "$ROOT does not look like mounted rootfs"

ROOTSRC="$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)"
[ "$ROOTSRC" = "$ROOTDEV" ] || die "$ROOT is '$ROOTSRC', expected '$ROOTDEV'"

[ "$(lsblk -n -o FSTYPE "$BOOTDEV" 2>/dev/null || true)" = "vfat" ] || die "$BOOTDEV is not VFAT"

if mountpoint -q "$ROOT/boot"; then
    BOOTSRC="$(findmnt -n -o SOURCE --target "$ROOT/boot" 2>/dev/null || true)"
    [ "$BOOTSRC" = "$BOOTDEV" ] || die "$ROOT/boot is '$BOOTSRC', expected '$BOOTDEV'"
else
    mount "$BOOTDEV" "$ROOT/boot"
fi

[ -s "$ROOT/boot/Image" ] || die "actual boot Image missing"

echo "Confirming actual boot Image still matches the current V5.3 build..."
cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image does not match current built Image"

cp -a "$K/.config" "$REPORT/backups/config.before-v5.4"
cp -a "$DEBUG_SCRIPT" "$REPORT/backups/c20e-usb-debug.before-v5.4"
cp -a "$ROOT/boot/Image" "$REPORT/backups/Image.actual-boot.before-v5.4"
[ ! -f "$INSTALLER" ] || cp -a "$INSTALLER" "$REPORT/backups/install-c20e-usb-debug.before-v5.4"

sha256sum "$IMG" "$ROOT/boot/Image" >"$REPORT/image-before.sha256"

echo "===== 1/6 enable gadget serial kernel console ====="

"$K/scripts/config" --file "$K/.config" --enable U_SERIAL_CONSOLE

CROSS="$(command -v aarch64-linux-gnu-gcc || true)"
[ -n "$CROSS" ] || die "aarch64-linux-gnu-gcc not found"
CROSS="${CROSS%gcc}"
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"

make -C "$K" olddefconfig

grep -q '^CONFIG_U_SERIAL_CONSOLE=y' "$K/.config" || die "CONFIG_U_SERIAL_CONSOLE did not enable"
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

echo "===== 2/6 enable console attribute in the installed ACM gadget ====="

python3 - "$DEBUG_SCRIPT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
tag = '# c20e-v5.4-usb-kernel-console'
if tag not in t:
    anchor = 'mkdir -p "$G/functions/acm.usb0"\n'
    if anchor not in t:
        raise SystemExit('ACM creation line not found in c20e-usb-debug')
    block = 'mkdir -p "$G/functions/acm.usb0"\n# c20e-v5.4-usb-kernel-console\nif [ -w "$G/functions/acm.usb0/console" ]; then\n    echo 1 > "$G/functions/acm.usb0/console"\n    echo "Enabled kernel printk console on ttyGS0"\nelse\n    echo "WARNING: ACM console attribute is unavailable"\nfi\n'
    t = t.replace(anchor, block, 1)
p.write_text(t)
PY

chmod 0755 "$DEBUG_SCRIPT"
grep -q '# c20e-v5.4-usb-kernel-console' "$DEBUG_SCRIPT" || die "installed USB console patch missing"
grep -q 'functions/acm.usb0/console' "$DEBUG_SCRIPT" || die "installed ACM console attribute write missing"

echo "===== 3/6 preserve the change in the reusable installer ====="

if [ -f "$INSTALLER" ]; then
    python3 - "$INSTALLER" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
tag = '# c20e-v5.4-usb-kernel-console'
if tag not in t:
    anchor = 'mkdir -p "$G/functions/acm.usb0"\n'
    if anchor not in t:
        raise SystemExit('ACM creation line not found in installer')
    block = 'mkdir -p "$G/functions/acm.usb0"\n# c20e-v5.4-usb-kernel-console\nif [ -w "$G/functions/acm.usb0/console" ]; then\n    echo 1 > "$G/functions/acm.usb0/console"\n    echo "Enabled kernel printk console on ttyGS0"\nelse\n    echo "WARNING: ACM console attribute is unavailable"\nfi\n'
    t = t.replace(anchor, block, 1)
p.write_text(t)
PY
    chmod 0755 "$INSTALLER"
    grep -q '# c20e-v5.4-usb-kernel-console' "$INSTALLER" || die "installer USB console patch missing"
else
    echo "NOTE: reusable installer not found; installed rootfs script was patched."
fi

echo "===== 4/6 rebuild kernel Image ====="

make -C "$K" -j"$(nproc)" Image

[ -s "$IMG" ] || die "rebuilt Image missing"
grep -q '^CONFIG_U_SERIAL_CONSOLE=y' "$K/.config" || die "USB serial console config missing after build"

sha256sum "$IMG" >"$REPORT/build-image.sha256"

echo "===== 5/6 deploy rebuilt Image to actual VFAT boot partition ====="

[ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" = "$BOOTDEV" ] || die "actual boot partition is no longer mounted"

install -m 0644 "$IMG" "$ROOT/boot/Image"
sync

cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image byte mismatch"
sha256sum "$ROOT/boot/Image" >"$REPORT/actual-boot-image.sha256"

echo "===== 6/6 final validation ====="

cp -a "$K/.config" "$REPORT/config-used"
cp -a "$DEBUG_SCRIPT" "$REPORT/c20e-usb-debug.final"
[ ! -f "$INSTALLER" ] || cp -a "$INSTALLER" "$REPORT/install-c20e-usb-debug.final"

diff -u "$REPORT/backups/config.before-v5.4" "$K/.config" >"$REPORT/config.diff" || true
diff -u "$REPORT/backups/c20e-usb-debug.before-v5.4" "$DEBUG_SCRIPT" >"$REPORT/c20e-usb-debug.diff" || true
if [ -f "$REPORT/backups/install-c20e-usb-debug.before-v5.4" ] && [ -f "$INSTALLER" ]; then
    diff -u "$REPORT/backups/install-c20e-usb-debug.before-v5.4" "$INSTALLER" >"$REPORT/installer.diff" || true
fi

grep -E '^(CONFIG_U_SERIAL_CONSOLE=|CONFIG_USB_GADGET=|CONFIG_USB_U_SERIAL=|CONFIG_USB_CONFIGFS=|CONFIG_USB_CONFIGFS_ACM=|CONFIG_DRM_PANFROST=|# CONFIG_MALI_BIFROST|CONFIG_TYPEC_HUSB320=|CONFIG_VIDEO_GC02M1=|CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|# CONFIG_DYNAMIC_FTRACE)' "$K/.config" >"$REPORT/protected-config.txt" || true

systemctl --root="$ROOT" is-enabled c20e-usb-debug.service >"$REPORT/usb-debug-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service >"$REPORT/ttygs0-enabled.txt" 2>&1 || true

tar -C "$REPO" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"

echo
echo "PASS: C20e V5.4 USB kernel console integration completed."
echo "The ACM function dynamically registers ttyGS0 as a kernel printk console."
echo "Because the kernel console uses CON_PRINTBUFFER, buffered kernel messages are replayed when USB ACM comes online."
echo "U-Boot output still cannot be captured through this Linux ConfigFS gadget."
echo "Report archive: $REPORT.tar.gz"
echo "Do not boot until the report is reviewed."
