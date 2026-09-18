#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
DEV="${2:-/dev/sda}"
ROOT="/mnt/c20e-v5.7r5"
BOOT="$ROOT/boot"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"

K="$REPO/src/kernel"
IMG="$K/arch/arm64/boot/Image"

PIN="b1b15016119cb21965fc64dd374e42f46f011bb4"
SRCROOT="$REPO/c20e-thirdparty"
SRC="$SRCROOT/seekwave-swt6621s"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-analysis/c20e-v5.7r5-modern-seekwave-sv6160-$STAMP"
LOG="$REPORT/full.log"
WORKCFG="$REPORT/kernel.config.work"

RUN_USER="${SUDO_USER:-root}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
[[ -n "$RUN_HOME" ]] || RUN_HOME="/root"

mkdir -p "$REPORT/backups"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

CONFIG_SAVED=0
CARD_MOUNTED=0
CARD_MUTATED=0
KREL=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

runu() {
    if [[ "$RUN_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$RUN_USER" env HOME="$RUN_HOME" "$@"
    fi
}

cfg_state() {
    runu "$K/scripts/config" --file "$WORKCFG" --state "$1" 2>/dev/null || true
}

assert_off() {
    local sym="$1"
    local state
    state="$(cfg_state "$sym")"
    printf '%-32s %s\n' "$sym" "${state:-undef}" | tee -a "$REPORT/seekwave-config-state.txt"
    case "$state" in
        n|undef|"") ;;
        *) die "$sym is still '$state'; expected n/undef." ;;
    esac
}

cleanup() {
    rc=$?
    set +e

    if [[ $rc -ne 0 && $CARD_MUTATED -eq 1 && $CARD_MOUNTED -eq 1 ]]; then
        echo
        echo "Failure after SD mutation; restoring V5.5 card-side backups."
        [[ -f "$REPORT/backups/Image.card.before-v5.7r5" ]] && cp -f "$REPORT/backups/Image.card.before-v5.7r5" "$BOOT/Image"
        [[ -f "$REPORT/backups/extlinux.conf.before-v5.7r5" ]] && cp -f "$REPORT/backups/extlinux.conf.before-v5.7r5" "$BOOT/extlinux/extlinux.conf"
        rm -rf "$ROOT/lib/modules/${KREL}/updates/c20e-seekwave" 2>/dev/null || true
        rm -f "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf" 2>/dev/null || true
        rm -f "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf" 2>/dev/null || true
        if [[ -f "$REPORT/backups/c20e-seekwave-v5.7.modules-load.conf" ]]; then
            cp -f "$REPORT/backups/c20e-seekwave-v5.7.modules-load.conf" "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf"
        fi
        if [[ -f "$REPORT/backups/c20e-seekwave-v5.7.modprobe.conf" ]]; then
            cp -f "$REPORT/backups/c20e-seekwave-v5.7.modprobe.conf" "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf"
        fi
        [[ -n "$KREL" ]] && depmod -b "$ROOT" "$KREL" >/dev/null 2>&1 || true
        sync
    fi

    mountpoint -q "$BOOT" && umount "$BOOT"
    mountpoint -q "$ROOT" && umount "$ROOT"
    rmdir "$ROOT" 2>/dev/null || true

    if [[ $rc -ne 0 && $CONFIG_SAVED -eq 1 ]]; then
        echo "Restoring local kernel .config and pre-V5.7r5 Image."
        cp -f "$REPORT/backups/kernel.config.before-v5.7r5" "$K/.config" 2>/dev/null || true
        cp -f "$REPORT/backups/Image.build-tree.before-v5.7r5" "$IMG" 2>/dev/null || true
        chown "$RUN_USER:$RUN_GROUP" "$K/.config" "$IMG" 2>/dev/null || true
    fi

    chown -R "$RUN_USER:$RUN_GROUP" "$REPORT" 2>/dev/null || true
    [[ -d "$SRCROOT" ]] && chown -R "$RUN_USER:$RUN_GROUP" "$SRCROOT" 2>/dev/null || true

    echo "[$(date -Is)] EXIT rc=$rc"
    exit "$rc"
}
trap cleanup EXIT

echo "=== C20e V5.7r5 modern Seekwave SV6160 integration ==="
echo "Time:       $(date -Is)"
echo "Repo:       $REPO"
echo "SD target:  $DEV"
echo "Kernel:     $K"
echo "Driver pin: retro98boy/seekwave-swt6621s@$PIN"
echo "Run user:   $RUN_USER:$RUN_GROUP"
echo

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -d "$K" ]] || die "Kernel tree missing: $K"
[[ -f "$K/.config" ]] || die "Kernel .config missing."
[[ -s "$IMG" ]] || die "Current kernel Image missing."
[[ -b "$DEV" && -b "$ROOTDEV" && -b "$BOOTDEV" ]] || die "Expected $DEV with partitions 3 and 4."

for cmd in git make python3 aarch64-linux-gnu-gcc e2fsck fsck.vfat depmod modinfo sha256sum blkid lsblk; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
done

BASE="$(basename "$DEV")"
[[ "$BASE" != nvme* && "$BASE" != mmcblk* ]] || die "Refusing $DEV; expected external USB SD reader."

SIZE="$(blockdev --getsize64 "$DEV")"
(( SIZE >= 30000000000 && SIZE <= 33000000000 )) || die "$DEV size $SIZE bytes is not the expected 32 GB-class card."

MODEL="$(lsblk -dn -o MODEL "$DEV" | xargs || true)"
[[ "$MODEL" == "Storage Device" ]] || die "$DEV model is '$MODEL', expected 'Storage Device'."

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$DEV"
    die "One or more target partitions are mounted."
fi

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOTDEV" 2>/dev/null || true)"
[[ "$ROOT_PARTUUID" == "c0ffee11-2233-4455-6677-8899aabbccdd" ]] || die "Unexpected root PARTUUID '$ROOT_PARTUUID'."

echo "===== 1/13 normalize local build-tree ownership ====="
find "$K" -xdev \( ! -user "$RUN_USER" -o ! -group "$RUN_GROUP" \) -printf '%u:%g %p\n' > "$REPORT/kernel-nonuser-owned.before.txt" 2>/dev/null || true
OWN_COUNT="$(wc -l < "$REPORT/kernel-nonuser-owned.before.txt")"
echo "Kernel-tree entries not owned by $RUN_USER:$RUN_GROUP before repair: $OWN_COUNT"
if (( OWN_COUNT > 0 )); then
    chown -R "$RUN_USER:$RUN_GROUP" "$K"
fi
mkdir -p "$SRCROOT"
chown -R "$RUN_USER:$RUN_GROUP" "$SRCROOT"
chown -R "$RUN_USER:$RUN_GROUP" "$REPORT"

echo
echo "===== 2/13 preserve current kernel state transactionally ====="
cp -a "$K/.config" "$REPORT/backups/kernel.config.before-v5.7r5"
cp -a "$IMG" "$REPORT/backups/Image.build-tree.before-v5.7r5"
cp -a "$K/.config" "$WORKCFG"
chown "$RUN_USER:$RUN_GROUP" "$WORKCFG"
CONFIG_SAVED=1
sha256sum "$IMG" | tee "$REPORT/Image.build-tree.before-v5.7r5.sha256"
runu git -C "$K" rev-parse HEAD | tee "$REPORT/kernel-git-head.txt"
runu git -C "$K" status --short > "$REPORT/kernel-git-status.before.txt" || true

echo
echo "===== 3/13 fetch/reset pinned modern Seekwave source ====="
if [[ -d "$SRC/.git" ]]; then
    runu git -C "$SRC" fetch --prune origin
else
    rm -rf "$SRC"
    runu git clone https://github.com/retro98boy/seekwave-swt6621s.git "$SRC"
fi
runu git -C "$SRC" checkout --detach "$PIN"
runu git -C "$SRC" reset --hard "$PIN"
runu git -C "$SRC" clean -fdx
[[ "$(runu git -C "$SRC" rev-parse HEAD)" == "$PIN" ]] || die "Seekwave source pin mismatch."
runu git -C "$SRC" log -1 --oneline | tee "$REPORT/seekwave-source.txt"

echo
echo "===== 4/13 adapt driver from SV6160LITE default to full SV6160 ====="
runu python3 -c 'from pathlib import Path; p=Path("'"$SRC"'/drivers/seekwaveplatform_lite/skwutil/skw_boot.c"); s=p.read_text(); a="#define CHIP_DEV_NAME \"sv6160lite\""; b="#define CHIP_DEV_NAME \"sv6160\""; assert a in s, "CHIP_DEV_NAME anchor missing"; s=s.replace(a,b,1); a="static char *local_chip_id = \"SV6160LITE\";"; b="static char *local_chip_id = \"SV6160\";"; assert a in s, "local_chip_id anchor missing"; p.write_text(s.replace(a,b,1))'
echo "Applying GCC 16 compatibility fix to SKW_ZALLOC..."
runu python3 -c 'from pathlib import Path; p=Path("'"$SRC"'/drivers/swt6621s_wifi/skw_util.h"); s=p.read_text(); a="#define SKW_ZALLOC(s, f)             ((s) ? kzalloc(s, f) : NULL)"; b="#define SKW_ZALLOC(s, f)             (((s) != 0) ? kzalloc((s), (f)) : NULL)"; assert a in s, "SKW_ZALLOC anchor missing"; p.write_text(s.replace(a,b,1))'

echo "Disabling vendor Bluetooth log port for the Wi-Fi-only test..."
runu python3 -c 'from pathlib import Path; p=Path("'"$SRC"'/drivers/seekwaveplatform_lite/skwutil/skw_btlog.h"); s=p.read_text(); a="//#define SKWBT_LOG_PORT_EN 0"; b="#define SKWBT_LOG_PORT_EN 0"; assert a in s, "SKWBT_LOG_PORT_EN anchor missing"; p.write_text(s.replace(a,b,1))'

runu git -C "$SRC" diff --check
runu git -C "$SRC" diff > "$REPORT/seekwave-c20e.patch"

grep -nE 'local_chip_id|CHIP_DEV_NAME' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_boot.c" | head -20 | tee "$REPORT/c20e-sv6160-adaptation.txt"
grep -q '#define CHIP_DEV_NAME "sv6160"' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_boot.c" || die "SV6160 compatible patch failed."
grep -q 'KERNEL_VERSION(6, 1, 0)' "$SRC/drivers/swt6621s_wifi/skw_compat.h" || die "Pinned source lacks Linux 6.1 cfg80211 fix."
grep -q 'MODEM_ENABLE_GPIO.*-1' "$SRC/drivers/seekwaveplatform_lite/skwutil/boot_config.h" || die "Pinned source still has hard-coded modem-enable GPIO."
grep -Fq '#define SKW_ZALLOC(s, f)             (((s) != 0) ? kzalloc((s), (f)) : NULL)' "$SRC/drivers/swt6621s_wifi/skw_util.h" || die "SKW_ZALLOC GCC 16 fix did not apply."
grep -Fxq '#define SKWBT_LOG_PORT_EN 0' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_btlog.h" || die "Wi-Fi-only BT log disable did not apply."

BOOTCFG="$SRC/drivers/seekwaveplatform_lite/skwutil/boot_config.h"
grep -nE 'CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT|CONFIG_SEEKWAVE_FIRMWARE_LOAD|SKW_SPEC_FW_PATH|SWT6621.*SDIO' "$BOOTCFG" > "$REPORT/firmware-mode-source.txt" || true
if grep -Eq '^[[:space:]]*#define[[:space:]]+CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT([[:space:]]|$)' "$BOOTCFG"; then
    die "Pinned source actively enables CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT."
fi
if grep -RIEq --include='Makefile' --include='Kconfig' --include='*.mk' -- '-D[[:space:]]*CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT|DCONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT' "$SRC"; then
    die "Pinned build files force CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT."
fi
echo "Firmware mode: standard request_firmware path; module firmware_dir=seekwave will be used." | tee "$REPORT/firmware-mode-validation.txt"

echo
echo "===== 5/13 create isolated kernel config with old Seekwave disabled ====="
: > "$REPORT/seekwave-config-state.txt"
for sym in SEEKWAVE_BSP_DRIVERS SKW_SDIOHAL SKW_BSP_UCOM SKW_BSP_BOOT WLAN_VENDOR_SEEKWAVE SKW_VENDOR SKW_BT; do
    runu "$K/scripts/config" --file "$WORKCFG" --disable "$sym"
done

CROSS="$(command -v aarch64-linux-gnu-gcc)"
CROSS="${CROSS%gcc}"

runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$WORKCFG" make -C "$K" olddefconfig

assert_off SEEKWAVE_BSP_DRIVERS
assert_off SKW_SDIOHAL
assert_off SKW_BSP_UCOM
assert_off SKW_BSP_BOOT
assert_off WLAN_VENDOR_SEEKWAVE
assert_off SKW_VENDOR
assert_off SKW_BT

for req in \
    'CONFIG_DRM_PANFROST=y' \
    '# CONFIG_MALI_BIFROST is not set' \
    'CONFIG_TYPEC_HUSB320=y' \
    'CONFIG_VIDEO_GC02M1=y' \
    'CONFIG_VIDEO_OV5648=y' \
    'CONFIG_VIDEO_DW9714=y' \
    'CONFIG_USB_GADGET=y' \
    'CONFIG_USB_CONFIGFS_ACM=y' \
    '# CONFIG_U_SERIAL_CONSOLE is not set' \
    '# CONFIG_DYNAMIC_FTRACE is not set' \
    'CONFIG_MODULES=y' \
    'CONFIG_FW_LOADER=y' \
    'CONFIG_MMC=y'; do
    grep -Fxq "$req" "$WORKCFG" || die "Protected config missing: $req"
done

grep -Eq '^CONFIG_CFG80211=(y|m)$' "$WORKCFG" || die "CFG80211 unavailable."
if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$WORKCFG"; then
    die "Kernel enforces signed modules."
fi

diff -u "$REPORT/backups/kernel.config.before-v5.7r5" "$WORKCFG" > "$REPORT/kernel.config.diff" || true

echo
echo "===== 6/13 rebuild kernel Image without old in-tree Seekwave ====="
# A failed prior run may restore the old Image with a newer timestamp than vmlinux.
# Remove only the generated Image target so Kbuild must regenerate it from the
# configuration-selected vmlinux instead of accepting a stale restored Image.
rm -f "$IMG"
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$WORKCFG" make -C "$K" -j"$(nproc)" Image
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$WORKCFG" make -C "$K" modules_prepare
[[ -s "$IMG" ]] || die "Rebuilt kernel Image missing."
sha256sum "$IMG" | tee "$REPORT/Image.v5.7r5.sha256"

if cmp -s "$IMG" "$REPORT/backups/Image.build-tree.before-v5.7r5"; then
    die "Rebuilt Image is byte-identical to the pre-V5.7 Image; refusing a potentially stale kernel artifact."
fi

CROSS_NM="${CROSS}nm"
[[ -x "$CROSS_NM" ]] || CROSS_NM="$(command -v aarch64-linux-gnu-nm || true)"
[[ -n "$CROSS_NM" ]] || die "aarch64-linux-gnu-nm not found."
"$CROSS_NM" "$K/vmlinux" > "$REPORT/vmlinux-nm.txt"
if grep -Eq '[[:space:]](seekwave_boot_probe|skw_sdio_scan_card)$' "$REPORT/vmlinux-nm.txt"; then
    grep -E '[[:space:]](seekwave_boot_probe|skw_sdio_scan_card)$' "$REPORT/vmlinux-nm.txt" | tee "$REPORT/old-seekwave-symbols-found.txt"
    die "Old in-tree Seekwave symbols are still built into vmlinux."
fi
echo "Kernel validation: old built-in Seekwave probe/scan symbols are absent." | tee "$REPORT/kernel-seekwave-validation.txt"

KREL="$(runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$WORKCFG" make -s -C "$K" kernelrelease)"
[[ -n "$KREL" ]] || die "Could not determine kernel release."
echo "$KREL" | tee "$REPORT/kernelrelease.txt"

echo
echo "===== 7/13 build modern Seekwave BSP + Wi-Fi only against this exact kernel ====="
# V5.7r5 deliberately does NOT compile Bluetooth yet. The previous attempt
# exposed a vendor-header shadowing bug in swtbt4l; Wi-Fi is our current A/B scope.
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$WORKCFG" \
    make -C "$K" M="$SRC" -j"$(nproc)" \
    CONFIG_SEEKWAVE_BSP_DRIVERS=m \
    CONFIG_SKW_SDIOHAL=m \
    CONFIG_SKW_BT=n \
    CONFIG_WLAN_VENDOR_SWT6621S=m \
    modules

SDIOKO="$SRC/drivers/seekwaveplatform_lite/skw_sdio_lite.ko"
WIFIKO="$SRC/drivers/swt6621s_wifi/swt6621s_wifi.ko"

[[ -s "$SDIOKO" ]] || die "skw_sdio_lite.ko was not built."
[[ -s "$WIFIKO" ]] || die "swt6621s_wifi.ko was not built."

sha256sum "$SDIOKO" "$WIFIKO" | tee "$REPORT/seekwave-modules.sha256"
for m in "$SDIOKO" "$WIFIKO"; do
    echo "--- $(basename "$m") ---"
    modinfo "$m" | grep -E '^(filename|version|license|description|vermagic|depends|name):' || true
done | tee "$REPORT/seekwave-modinfo.txt"

grep -q "vermagic:.*$KREL" "$REPORT/seekwave-modinfo.txt" || die "Seekwave module vermagic does not match $KREL."

echo
echo "===== 8/13 preflight required full-SV6160 firmware before touching SD ====="
for f in SWT6621_IRAM_SDIO.bin SWT6621_DRAM_SDIO.bin EA6621Q_SEEKWAVE_R00005.bin; do
    [[ -s "$REPO/overlay/firmware/$f" ]] || die "Missing C20e firmware: overlay/firmware/$f"
done
[[ -s "$REPO/overlay/drivers/net/wireless/ea6621q/swtbt4l/sv6160.nvbin" ]] || die "Missing C20e sv6160.nvbin."
sha256sum \
    "$REPO/overlay/firmware/SWT6621_IRAM_SDIO.bin" \
    "$REPO/overlay/firmware/SWT6621_DRAM_SDIO.bin" \
    "$REPO/overlay/firmware/EA6621Q_SEEKWAVE_R00005.bin" \
    "$REPO/overlay/drivers/net/wireless/ea6621q/swtbt4l/sv6160.nvbin" \
    | tee "$REPORT/source-firmware.sha256"

echo
echo "===== 9/13 repair and mount C20e SD ====="
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

mkdir -p "$ROOT"
mount "$ROOTDEV" "$ROOT"
mkdir -p "$BOOT"
mount "$BOOTDEV" "$BOOT"
CARD_MOUNTED=1

[[ "$(findmnt -n -o SOURCE --target "$ROOT")" == "$ROOTDEV" ]] || die "Root mount mismatch."
[[ "$(findmnt -n -o SOURCE --target "$BOOT")" == "$BOOTDEV" ]] || die "Boot mount mismatch."
[[ -f "$BOOT/extlinux/extlinux.conf" ]] || die "extlinux.conf missing."
[[ "$(cat "$ROOT/etc/hostname" 2>/dev/null)" == "gregdebtab" ]] || die "Unexpected rootfs hostname."
[[ -e "$ROOT/var/lib/c20e/firstboot-complete" ]] || die "firstboot-complete marker missing."

cmp -s "$REPORT/backups/Image.build-tree.before-v5.7r5" "$BOOT/Image" || die "Card Image no longer matches the known pre-V5.7 kernel."

cp -a "$BOOT/Image" "$REPORT/backups/Image.card.before-v5.7r5"
cp -a "$BOOT/extlinux/extlinux.conf" "$REPORT/backups/extlinux.conf.before-v5.7r5"
[[ -f "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf" ]] && cp -a "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf" "$REPORT/backups/c20e-seekwave-v5.7.modules-load.conf"
[[ -f "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf" ]] && cp -a "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf" "$REPORT/backups/c20e-seekwave-v5.7.modprobe.conf"

echo
echo "===== 10/13 deploy modern driver, firmware, and rebuilt Image ====="
CARD_MUTATED=1

MODDIR="$ROOT/lib/modules/$KREL/updates/c20e-seekwave"
mkdir -p "$MODDIR"
rm -f "$MODDIR"/*.ko "$MODDIR"/*.ko.xz "$MODDIR"/*.ko.zst
install -m 0644 "$SDIOKO" "$MODDIR/skw_sdio_lite.ko"
install -m 0644 "$WIFIKO" "$MODDIR/swt6621s_wifi.ko"

FW="$ROOT/lib/firmware/seekwave"
mkdir -p "$FW"
install -m 0644 "$REPO/overlay/firmware/SWT6621_IRAM_SDIO.bin" "$FW/"
install -m 0644 "$REPO/overlay/firmware/SWT6621_DRAM_SDIO.bin" "$FW/"
install -m 0644 "$REPO/overlay/firmware/EA6621Q_SEEKWAVE_R00005.bin" "$FW/"
install -m 0644 "$REPO/overlay/drivers/net/wireless/ea6621q/swtbt4l/sv6160.nvbin" "$FW/"

install -m 0644 "$IMG" "$BOOT/Image"
cmp -s "$IMG" "$BOOT/Image" || die "Deployed Image mismatch."

echo
echo "===== 11/13 configure first V5.7r5 boot as Wi-Fi-only diagnostic ====="
python3 -c 'from pathlib import Path; root=Path("'"$ROOT"'/etc/modules-load.d"); names={"skw_sdio","skw_bootcoms","skw","skwbt","skw_sdio_lite","swt6621s_wifi"}; [p.write_text("\n".join(("# c20e-v5.7r5: "+line if line.strip() in names else line) for line in p.read_text(errors="replace").splitlines())+"\n") for p in root.glob("*.conf") if p.name!="c20e-seekwave-v5.7.conf"]'
printf '%s\n' 'skw_sdio_lite' 'swt6621s_wifi' > "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf"

rm -f "$ROOT/etc/modprobe.d/c20e-v5.6-seekwave-isolation.conf"
printf '%s\n' \
    'options skw_sdio_lite firmware_dir=seekwave' \
    'options swt6621s_wifi firmware_dir=seekwave' \
    > "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf"

depmod -b "$ROOT" "$KREL"

systemctl --root="$ROOT" disable skwifi-loglevel.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" disable bluetooth.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true

python3 -c 'from pathlib import Path; import re; p=Path("'"$BOOT"'/extlinux/extlinux.conf"); s=p.read_text(); s2,n=re.subn(r"(?m)^default\s+\S+\s*$","default linux-debug",s,count=1); assert n==1, "default label not found"; p.write_text(s2)'

echo
echo "===== 12/13 final validation ====="
grep -E '^(default |label |[[:space:]]+append )' "$BOOT/extlinux/extlinux.conf" | tee "$REPORT/extlinux-summary.txt"
grep -RniE 'skw_sdio|skw_bootcoms|^skw$|skwbt|skw_sdio_lite|swt6621s_wifi' "$ROOT/etc/modules-load.d" > "$REPORT/modules-load-final.txt" 2>/dev/null || true
cat "$REPORT/modules-load-final.txt"
cat "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf" | tee "$REPORT/modprobe-final.txt"
find "$MODDIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort | tee "$REPORT/installed-modules.txt"
sha256sum "$BOOT/Image" "$BOOT/rk3562.dtb" | tee "$REPORT/boot-hashes.txt"
sha256sum "$FW/SWT6621_IRAM_SDIO.bin" "$FW/SWT6621_DRAM_SDIO.bin" "$FW/EA6621Q_SEEKWAVE_R00005.bin" "$FW/sv6160.nvbin" | tee "$REPORT/installed-firmware.sha256"

echo "Bluetooth driver is intentionally NOT compiled or installed in V5.7r5." | tee "$REPORT/test-scope.txt"
echo "Bluetooth service intentionally disabled for the first Wi-Fi-only stability boot." | tee -a "$REPORT/test-scope.txt"

echo
echo "===== 13/13 commit local config, sync, unmount, package ====="
cp -f "$WORKCFG" "$K/.config"
chown "$RUN_USER:$RUN_GROUP" "$K/.config" "$IMG"
sync

umount "$BOOT"
umount "$ROOT"
CARD_MOUNTED=0
CARD_MUTATED=0
rmdir "$ROOT" 2>/dev/null || true

trap - EXIT

tar -C "$REPO/c20e-analysis" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" | tee "$REPORT.tar.gz.sha256"

chown -R "$RUN_USER:$RUN_GROUP" "$REPORT" "$REPORT.tar.gz" "$REPORT.tar.gz.sha256" "$SRCROOT" 2>/dev/null || true

echo
echo "PASS: C20e V5.7r5 modern Seekwave SV6160 test prepared."
echo "  - old in-tree Seekwave disabled using isolated KCONFIG_CONFIG"
echo "  - modern driver pinned at $PIN"
echo "  - DT match adapted to seekwave,sv6160"
echo "  - full-SV6160 firmware retained"
echo "  - Wi-Fi BSP + Wi-Fi modules auto-load enabled"
echo "  - Bluetooth intentionally excluded from this build/test"
echo "  - GCC 16 SKW_ZALLOC warning fixed in the vendor source"
echo "  - vendor BT log port compiled out for this Wi-Fi-only test"
echo "  - rebuilt Image is checked against stale rollback artifacts"
echo "  - linux-debug selected"
echo
echo "Report: $REPORT.tar.gz"
echo "SHA256: $REPORT.tar.gz.sha256"
echo "SD filesystems are unmounted. Do not boot until the report is reviewed."
