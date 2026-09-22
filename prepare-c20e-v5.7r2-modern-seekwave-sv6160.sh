#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
DEV="${2:-/dev/sda}"
ROOT="/mnt/c20e-v5.7"
BOOT="$ROOT/boot"
K="$REPO/src/kernel"
IMG="$K/arch/arm64/boot/Image"
PIN="b1b15016119cb21965fc64dd374e42f46f011bb4"
SRCROOT="$REPO/c20e-thirdparty"
SRC="$SRCROOT/seekwave-swt6621s"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-analysis/c20e-v5.7r2-modern-seekwave-sv6160-$STAMP"
LOG="$REPORT/full.log"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"

mkdir -p "$REPORT/backups"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

RUN_USER="${SUDO_USER:-root}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
[[ -n "$RUN_HOME" ]] || RUN_HOME="/root"

runu() {
    if [[ "$RUN_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$RUN_USER" env HOME="$RUN_HOME" "$@"
    fi
}

CONFIG_SAVED=0
LOCAL_COMMITTED=0

cleanup() {
    rc=$?
    set +e
    mountpoint -q "$BOOT" && umount "$BOOT"
    mountpoint -q "$ROOT" && umount "$ROOT"
    rmdir "$ROOT" 2>/dev/null || true

    if [[ $rc -ne 0 && $CONFIG_SAVED -eq 1 && $LOCAL_COMMITTED -eq 0 ]]; then
        echo "Build/deploy failed; restoring local kernel .config and pre-V5.7 Image."
        cp -f "$REPORT/backups/kernel.config.before-v5.7" "$K/.config" 2>/dev/null || true
        cp -f "$REPORT/backups/Image.build-tree.before-v5.7" "$IMG" 2>/dev/null || true
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$RUN_USER":"$RUN_GROUP" "$REPORT" 2>/dev/null || true
        [[ -d "$SRCROOT" ]] && chown -R "$RUN_USER":"$RUN_GROUP" "$SRCROOT" 2>/dev/null || true
    fi

    echo "[$(date -Is)] EXIT rc=$rc"
    exit "$rc"
}
trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "=== C20e V5.7r2 modern Seekwave SV6160 test ==="
echo "Time:       $(date -Is)"
echo "Repo:       $REPO"
echo "SD target:  $DEV"
echo "Kernel:     $K"
echo "Driver pin: retro98boy/seekwave-swt6621s@$PIN"
echo

[[ $EUID -eq 0 ]] || die "Run this script with sudo."
[[ -d "$K" ]] || die "Kernel tree not found: $K"
[[ -f "$K/.config" ]] || die "Kernel .config not found."
[[ -s "$IMG" ]] || die "Current kernel Image not found."
[[ -b "$DEV" && -b "$ROOTDEV" && -b "$BOOTDEV" ]] || die "Expected $DEV with partitions 3 and 4."

for cmd in git make python3 aarch64-linux-gnu-gcc e2fsck depmod modinfo sha256sum blkid lsblk; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
done

if ! command -v fsck.vfat >/dev/null 2>&1; then
    die "fsck.vfat is required (Fedora package: dosfstools)."
fi

BASE="$(basename "$DEV")"
[[ "$BASE" != nvme* && "$BASE" != mmcblk* ]] || die "Refusing $DEV; expected the external USB SD reader."

SIZE="$(blockdev --getsize64 "$DEV")"
(( SIZE >= 30000000000 && SIZE <= 33000000000 )) || die "$DEV is $SIZE bytes; expected the 32 GB-class C20e SD."

MODEL="$(lsblk -dn -o MODEL "$DEV" | xargs || true)"
[[ "$MODEL" == "Storage Device" ]] || die "$DEV model is '$MODEL', expected 'Storage Device'."

if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q '[^[:space:]]'; then
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$DEV"
    die "One or more target partitions are mounted."
fi

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOTDEV" 2>/dev/null || true)"
[[ "$ROOT_PARTUUID" == "c0ffee11-2233-4455-6677-8899aabbccdd" ]] || die "Unexpected root PARTUUID: '$ROOT_PARTUUID'."

echo "===== 1/12 preserve current local build state ====="
cp -a "$K/.config" "$REPORT/backups/kernel.config.before-v5.7"
cp -a "$IMG" "$REPORT/backups/Image.build-tree.before-v5.7"
CONFIG_SAVED=1
sha256sum "$IMG" | tee "$REPORT/Image.build-tree.before-v5.7.sha256"
runu git -C "$K" rev-parse HEAD | tee "$REPORT/kernel-git-head.txt"
runu git -C "$K" status --short > "$REPORT/kernel-git-status.before.txt" || true

echo
echo "===== 2/12 fetch pinned modern Seekwave driver ====="
# The script runs under sudo for SD access, but Git/build work must stay owned by
# the invoking user. Repair ownership deterministically before invoking git.
mkdir -p "$SRCROOT"
chown -R "$RUN_USER":"$RUN_GROUP" "$SRCROOT"
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
echo "===== 3/12 adapt driver for the C20e full SV6160 ====="
runu python3 -c 'from pathlib import Path; p=Path("'"$SRC"'/drivers/seekwaveplatform_lite/skwutil/skw_boot.c"); s=p.read_text(); a="#define CHIP_DEV_NAME \"sv6160lite\""; b="#define CHIP_DEV_NAME \"sv6160\""; assert a in s, "CHIP_DEV_NAME anchor missing"; s=s.replace(a,b,1); a="static char *local_chip_id = \"SV6160LITE\";"; b="static char *local_chip_id = \"SV6160\";"; assert a in s, "local_chip_id anchor missing"; p.write_text(s.replace(a,b,1))'
grep -nE 'CHIP_DEV_NAME|local_chip_id' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_boot.c" | head -20 | tee "$REPORT/c20e-sv6160-adaptation.txt"
runu git -C "$SRC" diff --check
runu git -C "$SRC" diff > "$REPORT/seekwave-c20e.patch"

grep -q '#define CHIP_DEV_NAME "sv6160"' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_boot.c" || die "SV6160 compatible patch failed."
grep -q 'KERNEL_VERSION(6, 1, 0)' "$SRC/drivers/swt6621s_wifi/skw_compat.h" || die "Pinned driver does not contain the Linux 6.1 cfg80211 compatibility fix."
grep -q 'MODEM_ENABLE_GPIO.*-1' "$SRC/drivers/seekwaveplatform_lite/skwutil/boot_config.h" || die "Pinned driver still has a hard-coded chip-enable GPIO."
BOOTCFG="$SRC/drivers/seekwaveplatform_lite/skwutil/boot_config.h"
grep -nE 'CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT|CONFIG_SEEKWAVE_FIRMWARE_LOAD|SKW_SPEC_FW_PATH|SWT6621.*SDIO' "$BOOTCFG" > "$REPORT/firmware-mode-source.txt" || true

# CONFIG_SEEKWAVE_FIRMWARE_LOAD is defined *inside* an inactive #if block in
# this source. The real switch is CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT. The old
# V5.7 script grepped the conditional #define and produced a false positive.
if grep -Eq '^[[:space:]]*#define[[:space:]]+CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT([[:space:]]|$)' "$BOOTCFG"; then
    die "Pinned driver actively enables CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT, which would select the /data firmware path."
fi
if grep -RIEq --include='Makefile' --include='Kconfig' --include='*.mk' -- '-D[[:space:]]*CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT|DCONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT' "$SRC"; then
    die "Pinned build files force CONFIG_SKW_FREE_FIRMWARE_MEM_SUPPORT."
fi
echo "Firmware mode validation: standard request_firmware path is active; V5.7 will use firmware_dir=seekwave." | tee "$REPORT/firmware-mode-validation.txt"

echo
echo "===== 4/12 remove the old in-tree Seekwave implementation from the kernel Image ====="
runu "$K/scripts/config" --file "$K/.config" --disable SEEKWAVE_BSP_DRIVERS
runu "$K/scripts/config" --file "$K/.config" --disable SKW_SDIOHAL
runu "$K/scripts/config" --file "$K/.config" --disable SKW_BSP_UCOM
runu "$K/scripts/config" --file "$K/.config" --disable SKW_BSP_BOOT
runu "$K/scripts/config" --file "$K/.config" --disable WLAN_VENDOR_SEEKWAVE
runu "$K/scripts/config" --file "$K/.config" --disable SKW_VENDOR
runu "$K/scripts/config" --file "$K/.config" --disable SKW_BT

CROSS="$(command -v aarch64-linux-gnu-gcc)"
CROSS="${CROSS%gcc}"

runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" make -C "$K" olddefconfig

grep -q '^# CONFIG_SEEKWAVE_BSP_DRIVERS is not set' "$K/.config" || die "Old Seekwave BSP did not disable."
grep -q '^# CONFIG_WLAN_VENDOR_SEEKWAVE is not set' "$K/.config" || die "Old Seekwave Wi-Fi driver did not disable."
grep -q '^# CONFIG_SKW_BT is not set' "$K/.config" || die "Old Seekwave BT driver did not disable."

grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost config drifted."
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Mali Bifrost config drifted."
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 config drifted."
grep -q '^CONFIG_VIDEO_GC02M1=y' "$K/.config" || die "GC02M1 config drifted."
grep -q '^CONFIG_VIDEO_OV5648=y' "$K/.config" || die "OV5648 config drifted."
grep -q '^CONFIG_VIDEO_DW9714=y' "$K/.config" || die "DW9714 config drifted."
grep -q '^CONFIG_USB_GADGET=y' "$K/.config" || die "USB gadget config drifted."
grep -q '^CONFIG_USB_CONFIGFS_ACM=y' "$K/.config" || die "USB ACM config drifted."
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "Dynamic ftrace unexpectedly enabled."
grep -q '^CONFIG_MODULES=y' "$K/.config" || die "Kernel module support is not enabled."
grep -q '^CONFIG_FW_LOADER=y' "$K/.config" || die "Firmware loader is not built in."
grep -q '^CONFIG_MMC=y' "$K/.config" || die "MMC support is not built in."
grep -Eq '^CONFIG_CFG80211=(y|m)$' "$K/.config" || die "CFG80211 is unavailable."
if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$K/.config"; then
    die "Kernel enforces signed modules; V5.7 test modules would not load."
fi

cp -a "$K/.config" "$REPORT/kernel.config.v5.7"
diff -u "$REPORT/backups/kernel.config.before-v5.7" "$K/.config" > "$REPORT/kernel.config.diff" || true

echo
echo "===== 5/12 rebuild kernel Image without the old Seekwave stack ====="
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" make -C "$K" -j"$(nproc)" Image
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" make -C "$K" modules_prepare
[[ -s "$IMG" ]] || die "Rebuilt Image is missing."
sha256sum "$IMG" | tee "$REPORT/Image.v5.7.sha256"

KREL="$(runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" make -s -C "$K" kernelrelease)"
[[ -n "$KREL" ]] || die "Could not determine kernel release."
echo "$KREL" | tee "$REPORT/kernelrelease.txt"

echo
echo "===== 6/12 build modern Seekwave stack as external modules ====="
runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" \
    make -C "$K" M="$SRC" -j"$(nproc)" \
    CONFIG_SEEKWAVE_BSP_DRIVERS=m \
    CONFIG_SKW_SDIOHAL=m \
    CONFIG_SKW_BSP_UCOM=m \
    CONFIG_SKW_BSP_BOOT=m \
    CONFIG_SKW_BT=m \
    CONFIG_WLAN_VENDOR_SWT6621S=m \
    modules

SDIOKO="$SRC/drivers/seekwaveplatform_lite/skw_sdio_lite.ko"
WIFIKO="$SRC/drivers/swt6621s_wifi/swt6621s_wifi.ko"
BTKO="$SRC/drivers/swtbt4l/skwbt.ko"

[[ -s "$SDIOKO" ]] || die "skw_sdio_lite.ko was not built."
[[ -s "$WIFIKO" ]] || die "swt6621s_wifi.ko was not built."
[[ -s "$BTKO" ]] || die "skwbt.ko was not built."

sha256sum "$SDIOKO" "$WIFIKO" "$BTKO" | tee "$REPORT/seekwave-modules.sha256"
for m in "$SDIOKO" "$WIFIKO" "$BTKO"; do
    echo "--- $m ---"
    modinfo "$m" | grep -E '^(filename|version|license|description|vermagic|depends|name):' || true
done | tee "$REPORT/seekwave-modinfo.txt"

grep -q "$KREL" "$REPORT/seekwave-modinfo.txt" || die "Module vermagic does not reference $KREL."

echo
echo "===== 7/12 repair and mount the C20e SD ====="
set +e
e2fsck -f -y "$ROOTDEV" | tee "$REPORT/e2fsck-rootfs.txt"
E2RC=${PIPESTATUS[0]}
set -e
case "$E2RC" in
    0|1|2) ;;
    *) die "e2fsck failed with rc=$E2RC" ;;
esac

set +e
fsck.vfat -a "$BOOTDEV" | tee "$REPORT/fsck-boot.txt"
VFRC=${PIPESTATUS[0]}
set -e
case "$VFRC" in
    0|1) ;;
    *) die "fsck.vfat failed with rc=$VFRC" ;;
esac

mkdir -p "$ROOT"
mount "$ROOTDEV" "$ROOT"
mkdir -p "$BOOT"
mount "$BOOTDEV" "$BOOT"

[[ "$(findmnt -n -o SOURCE --target "$ROOT")" == "$ROOTDEV" ]] || die "Root mount mismatch."
[[ "$(findmnt -n -o SOURCE --target "$BOOT")" == "$BOOTDEV" ]] || die "Boot mount mismatch."
[[ -f "$BOOT/extlinux/extlinux.conf" ]] || die "extlinux.conf not found."
[[ "$(cat "$ROOT/etc/hostname" 2>/dev/null)" == "gregdebtab" ]] || die "This does not look like the completed C20e rootfs."
[[ -e "$ROOT/var/lib/c20e/firstboot-complete" ]] || die "C20e firstboot-complete marker is missing."

cp -a "$BOOT/Image" "$REPORT/backups/Image.card.before-v5.7"
cp -a "$BOOT/extlinux/extlinux.conf" "$REPORT/backups/extlinux.conf.before-v5.7"
cp -a "$ROOT/etc/modules-load.d" "$REPORT/backups/modules-load.d.before-v5.7" 2>/dev/null || true
cp -a "$ROOT/etc/modprobe.d" "$REPORT/backups/modprobe.d.before-v5.7" 2>/dev/null || true
find "$ROOT/lib/modules/$KREL" -type f \( -name 'skw*.ko' -o -name 'skw*.ko.xz' -o -name 'skw*.ko.zst' \) -print > "$REPORT/old-seekwave-modules.txt" 2>/dev/null || true

echo
echo "===== 8/12 install V5.7 modules and C20e full-SV6160 firmware ====="
MODDIR="$ROOT/lib/modules/$KREL/updates/c20e-seekwave"
mkdir -p "$MODDIR"
rm -f "$MODDIR"/*.ko "$MODDIR"/*.ko.xz "$MODDIR"/*.ko.zst
install -m 0644 "$SDIOKO" "$MODDIR/skw_sdio_lite.ko"
install -m 0644 "$WIFIKO" "$MODDIR/swt6621s_wifi.ko"
install -m 0644 "$BTKO" "$MODDIR/skwbt.ko"

FW="$ROOT/lib/firmware/seekwave"
mkdir -p "$FW"
for f in SWT6621_IRAM_SDIO.bin SWT6621_DRAM_SDIO.bin EA6621Q_SEEKWAVE_R00005.bin; do
    [[ -s "$REPO/overlay/firmware/$f" ]] || die "Missing existing C20e full-SV6160 firmware: overlay/firmware/$f"
    install -m 0644 "$REPO/overlay/firmware/$f" "$FW/$f"
done
[[ -s "$REPO/overlay/drivers/net/wireless/ea6621q/swtbt4l/sv6160.nvbin" ]] || die "Missing sv6160.nvbin."
install -m 0644 "$REPO/overlay/drivers/net/wireless/ea6621q/swtbt4l/sv6160.nvbin" "$FW/sv6160.nvbin"

sha256sum "$FW/SWT6621_IRAM_SDIO.bin" "$FW/SWT6621_DRAM_SDIO.bin" "$FW/EA6621Q_SEEKWAVE_R00005.bin" "$FW/sv6160.nvbin" | tee "$REPORT/installed-firmware.sha256"

echo
echo "===== 9/12 deploy kernel and configure module loading ====="
install -m 0644 "$IMG" "$BOOT/Image"
sync
cmp -s "$IMG" "$BOOT/Image" || die "Actual boot Image does not match rebuilt V5.7 Image."
sha256sum "$BOOT/Image" | tee "$REPORT/Image.actual-boot.v5.7.sha256"

python3 -c 'from pathlib import Path; root=Path("'"$ROOT"'/etc/modules-load.d"); names={"skw_sdio","skw_bootcoms","skw","skwbt","skw_sdio_lite","swt6621s_wifi"}; [p.write_text("\n".join(("# c20e-v5.7: "+line if line.strip() in names else line) for line in p.read_text(errors="replace").splitlines())+"\n") for p in root.glob("*.conf") if p.name!="c20e-seekwave-v5.7.conf"]'
printf '%s\n' 'skw_sdio_lite' 'swt6621s_wifi' > "$ROOT/etc/modules-load.d/c20e-seekwave-v5.7.conf"

rm -f "$ROOT/etc/modprobe.d/c20e-v5.6-seekwave-isolation.conf"
printf '%s\n' 'options skw_sdio_lite firmware_dir=seekwave' 'options swt6621s_wifi firmware_dir=seekwave' 'options skwbt firmware_dir=seekwave' > "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf"

depmod -b "$ROOT" "$KREL"

systemctl --root="$ROOT" disable skwifi-loglevel.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" disable bluetooth.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true

echo
echo "===== 10/12 select diagnostic boot entry ====="
python3 -c 'from pathlib import Path; import re; p=Path("'"$BOOT"'/extlinux/extlinux.conf"); s=p.read_text(); s2,n=re.subn(r"(?m)^default\s+\S+\s*$","default linux-debug",s,count=1); assert n==1, "default label not found"; p.write_text(s2)'
grep -E '^(default |label |[[:space:]]+append )' "$BOOT/extlinux/extlinux.conf" | tee "$REPORT/extlinux-summary.txt"

echo
echo "===== 11/12 final offline validation ====="
grep -RniE 'skw_sdio|skw_bootcoms|^skw$|skwbt|skw_sdio_lite|swt6621s_wifi' "$ROOT/etc/modules-load.d" > "$REPORT/modules-load-final.txt" 2>/dev/null || true
cat "$REPORT/modules-load-final.txt"

cat "$ROOT/etc/modprobe.d/c20e-seekwave-v5.7.conf" | tee "$REPORT/modprobe-final.txt"
find "$MODDIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort | tee "$REPORT/installed-modules.txt"
readlink "$ROOT/etc/systemd/system/default.target" | tee "$REPORT/default-target.txt" || true

echo "Bluetooth is intentionally NOT auto-loaded in V5.7."
echo "V5.7 first proves the modern BSP + Wi-Fi path; skwbt.ko is installed for the next step."

echo
echo "===== 12/12 sync, unmount, and package report ====="
sync
umount "$BOOT"
umount "$ROOT"
rmdir "$ROOT" 2>/dev/null || true

LOCAL_COMMITTED=1
trap - EXIT

tar -C "$REPO/c20e-analysis" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" | tee "$REPORT.tar.gz.sha256"

if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$RUN_USER":"$RUN_GROUP" "$REPORT" "$REPORT.tar.gz" "$REPORT.tar.gz.sha256" "$SRCROOT" 2>/dev/null || true
fi

echo
echo "PASS: C20e V5.7r2 modern Seekwave SV6160 test prepared."
echo
echo "What changed:"
echo "  - Old in-tree EA6621Q Seekwave stack removed from the kernel Image."
echo "  - retro98boy modern driver pinned at $PIN."
echo "  - Driver adapted to bind the C20e factory compatible: seekwave,sv6160."
echo "  - Existing full-SV6160 firmware retained; SWT6621S/SV6160LITE firmware was NOT substituted."
echo "  - New skw_sdio_lite + swt6621s_wifi modules auto-load from /lib/modules/$KREL/updates/c20e-seekwave."
echo "  - skwbt.ko is installed but intentionally not auto-loaded yet."
echo "  - Bluetooth service disabled for the first Wi-Fi stability boot."
echo "  - extlinux default set to linux-debug for this test."
echo
echo "Report: $REPORT.tar.gz"
echo "SHA256: $REPORT.tar.gz.sha256"
echo
echo "The SD filesystems are unmounted. Review the report before booting."
