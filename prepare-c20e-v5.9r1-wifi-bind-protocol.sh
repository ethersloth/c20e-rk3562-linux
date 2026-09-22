#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-$HOME/Desktop/workspace/rk3562deb}"
TARGET="${TARGET:-/dev/sda}"
KERNEL="$REPO/src/kernel"
SKW="$REPO/c20e-thirdparty/seekwave-swt6621s"
WIFI_CORE="$SKW/drivers/swt6621s_wifi/skw_core.c"
KREL_EXPECTED="6.1.172"
BOOT_PARTUUID_EXPECTED="f2e4c648-207d-45f0-b5ad-7886f75e57eb"
ROOT_PARTUUID_EXPECTED="c0ffee11-2233-4455-6677-8899aabbccdd"
ROOT_LABEL_EXPECTED="rootfs"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$REPO/c20e-analysis"
BACKUP="$REPO/c20e-backup/v5.9r1-$STAMP"
LOG="$LOGDIR/c20e-v5.9r1-build-$STAMP.log"
MNT="/mnt/c20e-v59r1-root"

mkdir -p "$LOGDIR" "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    rc=$?
    if mountpoint -q "$MNT" 2>/dev/null; then
        sudo umount "$MNT" || true
    fi
    echo "[V5.9r1] exit=$rc"
    echo "[V5.9r1] log=$LOG"
    exit "$rc"
}
trap cleanup EXIT INT TERM

echo "=== C20e V5.9r1: Wi-Fi platform match + protocol V2 ==="
echo "[*] repo=$REPO"
echo "[*] target=$TARGET"
echo "[*] log=$LOG"

echo "[1/9] Host/source preflight"
for c in git make perl grep sha256sum lsblk blkid findmnt mount umount mountpoint modinfo depmod sudo; do
    command -v "$c" >/dev/null || { echo "[-] Missing required command: $c"; exit 1; }
done
command -v aarch64-linux-gnu-gcc >/dev/null || { echo "[-] Missing aarch64-linux-gnu-gcc"; exit 1; }
[[ -d "$REPO/.git" ]] || { echo "[-] Missing repo git tree: $REPO"; exit 1; }
[[ -d "$KERNEL/.git" ]] || { echo "[-] Missing nested kernel git tree: $KERNEL"; exit 1; }
[[ -d "$SKW/.git" ]] || { echo "[-] Missing Seekwave git tree: $SKW"; exit 1; }
[[ -f "$WIFI_CORE" ]] || { echo "[-] Missing Wi-Fi source: $WIFI_CORE"; exit 1; }
[[ -f "$KERNEL/Module.symvers" ]] || { echo "[-] Missing kernel Module.symvers"; exit 1; }

echo "[*] kernel HEAD=$(git -C "$KERNEL" rev-parse HEAD)"
echo "[*] seekwave HEAD=$(git -C "$SKW" rev-parse HEAD)"
echo "[*] kernel wrong-owner entries: $(find "$KERNEL" \( ! -user "$(id -un)" -o ! -group "$(id -gn)" \) | wc -l)"
echo "[*] seekwave wrong-owner entries: $(find "$SKW" \( ! -user "$(id -un)" -o ! -group "$(id -gn)" \) | wc -l)"

echo "[2/9] Storage safety checks"
[[ -b "$TARGET" ]] || { echo "[-] $TARGET is not a block device"; exit 1; }
HOST_ROOT="$(findmnt -n -o SOURCE /)"
MODEL="$(lsblk -dn -o MODEL "$TARGET" | xargs)"
SIZE="$(lsblk -dn -o SIZE "$TARGET" | xargs)"
BOOT_PART="${TARGET}3"
ROOT_PART="${TARGET}4"
BOOT_UUID="$(sudo blkid -s PARTUUID -o value "$BOOT_PART" 2>/dev/null || true)"
ROOT_UUID="$(sudo blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
ROOT_LABEL="$(sudo blkid -s LABEL -o value "$ROOT_PART" 2>/dev/null || true)"
echo "[*] host root device: $HOST_ROOT"
echo "[*] target model='$MODEL' size='$SIZE'"
echo "[*] boot PARTUUID=$BOOT_UUID"
echo "[*] root PARTUUID=$ROOT_UUID label=$ROOT_LABEL"
[[ "$HOST_ROOT" != "$TARGET"* ]] || { echo "[-] REFUSING: target backs the Fedora root filesystem"; exit 1; }
[[ "$MODEL" == "Storage Device" ]] || { echo "[-] REFUSING: unexpected target model '$MODEL'"; exit 1; }
[[ "$SIZE" == "29.1G" ]] || { echo "[-] REFUSING: unexpected target size '$SIZE'"; exit 1; }
[[ "$BOOT_UUID" == "$BOOT_PARTUUID_EXPECTED" ]] || { echo "[-] REFUSING: boot PARTUUID mismatch"; exit 1; }
[[ "$ROOT_UUID" == "$ROOT_PARTUUID_EXPECTED" ]] || { echo "[-] REFUSING: root PARTUUID mismatch"; exit 1; }
[[ "$ROOT_LABEL" == "$ROOT_LABEL_EXPECTED" ]] || { echo "[-] REFUSING: root label mismatch"; exit 1; }

echo "[3/9] Back up Wi-Fi source and apply permanent V5.9r1 fixes"
cp -a "$WIFI_CORE" "$BACKUP/skw_core.c.before-v5.9r1"

if grep -q 'SKW_CMD_VER(SKW_CMD_SET_SPD_ACTION, V1)' "$WIFI_CORE"; then
    perl -0pi -e 's/SKW_CMD_VER\(SKW_CMD_SET_SPD_ACTION,\s*V1\)/SKW_CMD_VER(SKW_CMD_SET_SPD_ACTION, V2)/g' "$WIFI_CORE"
fi

if ! grep -q 'static const struct platform_device_id skw_drv_ids\[\]' "$WIFI_CORE"; then
    perl -0pi -e 's/static struct platform_driver skw_drv = \{/static const struct platform_device_id skw_drv_ids[] = {\n\t{ "sv6160_wireless1", 0 },\n\t{ "sv6621s_wireless1", 0 },\n\t{ }\n};\nMODULE_DEVICE_TABLE(platform, skw_drv_ids);\n\nstatic struct platform_driver skw_drv = {/s' "$WIFI_CORE"
fi

if ! grep -q '\.id_table = skw_drv_ids' "$WIFI_CORE"; then
    perl -0pi -e 's/(static struct platform_driver skw_drv = \{\n\s*\.probe = skw_drv_probe,\n)/$1\t.id_table = skw_drv_ids,\n/s' "$WIFI_CORE"
fi

grep -n 'SKW_CMD_VER(SKW_CMD_SET_SPD_ACTION' "$WIFI_CORE"
grep -n -A12 -B2 'static const struct platform_device_id skw_drv_ids' "$WIFI_CORE"
grep -q 'SKW_CMD_VER(SKW_CMD_SET_SPD_ACTION, V2)' "$WIFI_CORE" || { echo "[-] Protocol V2 patch validation failed"; exit 1; }
grep -q '{ "sv6160_wireless1", 0 }' "$WIFI_CORE" || { echo "[-] SV6160 platform ID patch validation failed"; exit 1; }
grep -q '{ "sv6621s_wireless1", 0 }' "$WIFI_CORE" || { echo "[-] SV6621S platform ID preservation failed"; exit 1; }
grep -q '\.id_table = skw_drv_ids' "$WIFI_CORE" || { echo "[-] Wi-Fi id_table hook validation failed"; exit 1; }

echo "[4/9] Validate kernel release and protected configuration"
KREL="$(make -s -C "$KERNEL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
echo "[*] kernelrelease=$KREL"
[[ "$KREL" == "$KREL_EXPECTED" ]] || { echo "[-] Unexpected kernelrelease '$KREL'"; exit 1; }
grep -qx 'CONFIG_DRM_PANFROST=y' "$KERNEL/.config" || { echo "[-] Panfrost config changed"; exit 1; }
grep -qx '# CONFIG_MALI_BIFROST is not set' "$KERNEL/.config" || { echo "[-] Mali Bifrost config changed"; exit 1; }
grep -qx 'CONFIG_COMMON_CLK_RK808=y' "$KERNEL/.config" || { echo "[-] RK808 clock config missing"; exit 1; }
grep -qx 'CONFIG_VIDEO_GC02M1=y' "$KERNEL/.config" || { echo "[-] GC02M1 config changed"; exit 1; }
grep -qx 'CONFIG_VIDEO_OV5648=y' "$KERNEL/.config" || { echo "[-] OV5648 config changed"; exit 1; }
grep -qx 'CONFIG_VIDEO_DW9714=y' "$KERNEL/.config" || { echo "[-] DW9714 config changed"; exit 1; }

echo "[5/9] Rebuild modern Seekwave BSP + Wi-Fi only"
JOBS="${JOBS:-$(nproc)}"
[[ "$JOBS" -gt 8 ]] && JOBS=8
echo "[*] build jobs=$JOBS"
make -C "$KERNEL" M="$SKW" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
make -j"$JOBS" -C "$KERNEL" M="$SKW" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KCFLAGS="-Wno-error=int-in-bool-context" CONFIG_SEEKWAVE_BSP_DRIVERS=m CONFIG_SKW_NO_CONFIG=y CONFIG_SKW_SDIOHAL=m CONFIG_WLAN_VENDOR_SWT6621S=m CONFIG_SKW_BT=n CONFIG_SWT6621S_LOG_DEBUG=y modules

BSP_KO="$SKW/drivers/seekwaveplatform_lite/skw_sdio_lite.ko"
WIFI_KO="$SKW/drivers/swt6621s_wifi/swt6621s_wifi.ko"
[[ -f "$BSP_KO" ]] || { echo "[-] BSP module was not produced"; exit 1; }
[[ -f "$WIFI_KO" ]] || { echo "[-] Wi-Fi module was not produced"; exit 1; }
echo "[*] BSP vermagic=$(modinfo -F vermagic "$BSP_KO")"
echo "[*] Wi-Fi vermagic=$(modinfo -F vermagic "$WIFI_KO")"
modinfo -F vermagic "$BSP_KO" | grep -q "^$KREL " || { echo "[-] BSP vermagic mismatch"; exit 1; }
modinfo -F vermagic "$WIFI_KO" | grep -q "^$KREL " || { echo "[-] Wi-Fi vermagic mismatch"; exit 1; }
sha256sum "$BSP_KO" "$WIFI_KO"

echo "[6/9] Mount verified rootfs and back up on-card state"
sudo -v
sudo mkdir -p "$MNT"
sudo mount "$ROOT_PART" "$MNT"
MODDIR="$MNT/lib/modules/$KREL/updates/c20e-seekwave"
sudo mkdir -p "$MODDIR"
if [[ -f "$MODDIR/skw_sdio_lite.ko" ]]; then
    sudo cp -a "$MODDIR/skw_sdio_lite.ko" "$BACKUP/skw_sdio_lite.ko.on-card-before"
fi
if [[ -f "$MODDIR/swt6621s_wifi.ko" ]]; then
    sudo cp -a "$MODDIR/swt6621s_wifi.ko" "$BACKUP/swt6621s_wifi.ko.on-card-before"
fi
if [[ -f "$MNT/etc/modules-load.d/c20e-seekwave-v5.9r1.conf" ]]; then
    sudo cp -a "$MNT/etc/modules-load.d/c20e-seekwave-v5.9r1.conf" "$BACKUP/c20e-seekwave-v5.9r1.conf.before"
fi

echo "[7/9] Deploy rebuilt BSP + Wi-Fi modules and autoload policy"
sudo install -m 0644 "$BSP_KO" "$MODDIR/skw_sdio_lite.ko"
sudo install -m 0644 "$WIFI_KO" "$MODDIR/swt6621s_wifi.ko"
printf '%s\n' 'skw_sdio_lite' 'swt6621s_wifi' | sudo tee "$MNT/etc/modules-load.d/c20e-seekwave-v5.9r1.conf" >/dev/null
sudo mkdir -p "$MNT/etc/modprobe.d"
printf '%s\n' 'softdep swt6621s_wifi pre: skw_sdio_lite' | sudo tee "$MNT/etc/modprobe.d/c20e-seekwave-v5.9r1.conf" >/dev/null
sudo depmod -b "$MNT" "$KREL"

echo "[8/9] Install V5.9r1 automatic Wi-Fi capture"
sudo tee "$MNT/usr/local/sbin/c20e-v5.9r1-capture" >/dev/null <<'CAPTURE'
#!/bin/sh
sleep 25
OUT=/var/log/c20e-v5.9r1-wifi-state.log
{
    echo "=== C20e V5.9r1 Wi-Fi capture ==="
    date
    uname -a
    echo
    echo "=== modules ==="
    lsmod | grep -E 'skw|swt' || true
    echo
    echo "=== platform devices ==="
    for d in /sys/bus/platform/devices/sv6160_wireless1* /sys/bus/platform/devices/sv6621s_wireless1*; do
        [ -e "$d" ] || continue
        echo "-- $d --"
        readlink "$d/driver" 2>/dev/null || echo UNBOUND
        cat "$d/modalias" 2>/dev/null || true
    done
    echo
    echo "=== network ==="
    ip -br link 2>/dev/null || true
    command -v iw >/dev/null 2>&1 && iw dev 2>/dev/null || true
    command -v rfkill >/dev/null 2>&1 && rfkill list 2>/dev/null || true
    echo
    echo "=== SDIO ==="
    for d in /sys/bus/sdio/devices/*; do
        [ -e "$d" ] || continue
        echo "-- $d --"
        cat "$d/vendor" 2>/dev/null || true
        cat "$d/device" 2>/dev/null || true
        readlink "$d/driver" 2>/dev/null || true
    done
    echo
    echo "=== filtered dmesg ==="
    dmesg | grep -Ei 'SKWIFI|SKWSDIO|SKWBOOT|sv6160|sv6621|swt6621|wlan|cfg80211|firmware|WIFIREADY|wifi_service|cmd: 58|thermal' || true
} >"$OUT" 2>&1
CAPTURE
sudo chmod 0755 "$MNT/usr/local/sbin/c20e-v5.9r1-capture"

sudo tee "$MNT/etc/systemd/system/c20e-v5.9r1-capture.service" >/dev/null <<'UNIT'
[Unit]
Description=C20e V5.9r1 Wi-Fi diagnostic capture
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-v5.9r1-capture

[Install]
WantedBy=multi-user.target
UNIT
sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sfn ../c20e-v5.9r1-capture.service "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9r1-capture.service"

echo "[9/9] Final verification and clean unmount"
echo "[*] deployed BSP:"
sha256sum "$MODDIR/skw_sdio_lite.ko"
echo "[*] deployed Wi-Fi:"
sha256sum "$MODDIR/swt6621s_wifi.ko"
echo "[*] modules-load:"
cat "$MNT/etc/modules-load.d/c20e-seekwave-v5.9r1.conf"
echo "[*] modprobe softdep:"
cat "$MNT/etc/modprobe.d/c20e-seekwave-v5.9r1.conf"
echo "[*] capture service:"
readlink "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9r1-capture.service"
sync
sudo umount "$MNT"

echo
echo "[+] C20e V5.9r1 deployment complete."
echo "[+] Permanent Wi-Fi fixes deployed:"
echo "    1) SV6160 platform device now matches swt6621s_wifi via platform id_table"
echo "    2) SKW_CMD_SET_SPD_ACTION protocol version changed V1 -> V2"
echo "    3) skw_sdio_lite + swt6621s_wifi configured to auto-load"
echo "[+] No kernel, DTB, display, camera, or bootchain files were modified on the SD card."
echo "[+] Boot diagnostics will be written to /var/log/c20e-v5.9r1-wifi-state.log"
echo "[+] Host backup: $BACKUP"
echo "[+] Build log: $LOG"
