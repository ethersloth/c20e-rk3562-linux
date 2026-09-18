#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-$HOME/Desktop/workspace/rk3562deb}"
TARGET="${TARGET:-/dev/sda}"
KERNEL="$REPO/src/kernel"
SKW="$REPO/c20e-thirdparty/seekwave-swt6621s"
CLK_SRC="$KERNEL/drivers/clk/clk-rk808.c"
SDIO_SRC="$SKW/drivers/seekwaveplatform_lite/sdio/skw_sdio_main.c"
BOOT_SRC="$SKW/drivers/seekwaveplatform_lite/skwutil/skw_boot.c"
BOOT_PART="${TARGET}3"
ROOT_PART="${TARGET}4"
EXPECTED_BOOT_PARTUUID="f2e4c648-207d-45f0-b5ad-7886f75e57eb"
EXPECTED_ROOT_PARTUUID="c0ffee11-2233-4455-6677-8899aabbccdd"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$REPO/c20e-analysis"
BACKUP="$REPO/c20e-backup/v5.9-$STAMP"
LOG="$LOGDIR/c20e-v5.9-build-$STAMP.log"
BOOT_MNT="/mnt/c20e-v59-boot"
ROOT_MNT="/mnt/c20e-v59-root"

mkdir -p "$LOGDIR" "$BACKUP"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "[V5.9] exit=$rc"; echo "[V5.9] log=$LOG"; exit $rc' EXIT

echo "=== C20e V5.9: RK817 clkout + Seekwave 0000:0000 fix ==="
echo "[*] repo=$REPO"
echo "[*] target=$TARGET"
echo "[*] log=$LOG"

cd "$REPO"

for cmd in git make aarch64-linux-gnu-gcc aarch64-linux-gnu-nm blkid lsblk findmnt strings sed grep awk tee sync; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[-] Missing command: $cmd"; exit 1; }
done

[ -d "$KERNEL/.git" ] || { echo "[-] Missing nested kernel git tree: $KERNEL"; exit 1; }
[ -d "$SKW/.git" ] || { echo "[-] Missing Seekwave checkout: $SKW"; exit 1; }
[ -f "$CLK_SRC" ] || { echo "[-] Missing $CLK_SRC"; exit 1; }
[ -f "$SDIO_SRC" ] || { echo "[-] Missing $SDIO_SRC"; exit 1; }
[ -f "$BOOT_SRC" ] || { echo "[-] Missing $BOOT_SRC"; exit 1; }

echo "[1/10] Storage safety checks"
ROOTDEV="$(findmnt -n -o SOURCE / || true)"
echo "[*] host root device: $ROOTDEV"
case "$ROOTDEV" in
    "$TARGET"|"$TARGET"[0-9]*) echo "[-] Refusing: TARGET backs the Fedora root filesystem."; exit 1 ;;
esac
MODEL="$(lsblk -dn -o MODEL "$TARGET" 2>/dev/null | sed 's/[[:space:]]*$//')"
SIZE="$(lsblk -dn -o SIZE "$TARGET" 2>/dev/null | sed 's/[[:space:]]//g')"
echo "[*] target model='$MODEL' size='$SIZE'"
[ "$MODEL" = "Storage Device" ] || { echo "[-] Unexpected target model; refusing."; exit 1; }
[ "$SIZE" = "29.1G" ] || { echo "[-] Unexpected target size; refusing."; exit 1; }
BOOT_UUID="$(sudo blkid -s PARTUUID -o value "$BOOT_PART" 2>/dev/null || true)"
ROOT_UUID="$(sudo blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
ROOT_LABEL="$(sudo blkid -s LABEL -o value "$ROOT_PART" 2>/dev/null || true)"
echo "[*] boot PARTUUID=$BOOT_UUID"
echo "[*] root PARTUUID=$ROOT_UUID label=$ROOT_LABEL"
[ "$BOOT_UUID" = "$EXPECTED_BOOT_PARTUUID" ] || { echo "[-] Boot PARTUUID mismatch; refusing."; exit 1; }
[ "$ROOT_UUID" = "$EXPECTED_ROOT_PARTUUID" ] || { echo "[-] Root PARTUUID mismatch; refusing."; exit 1; }
[ "$ROOT_LABEL" = "rootfs" ] || { echo "[-] Root label mismatch; refusing."; exit 1; }

echo "[2/10] Source preflight and backups"
cp -a "$CLK_SRC" "$BACKUP/clk-rk808.c.before"
cp -a "$SDIO_SRC" "$BACKUP/skw_sdio_main.c.before"
cp -a "$BOOT_SRC" "$BACKUP/skw_boot.c.before"
git -C "$KERNEL" rev-parse HEAD | tee "$BACKUP/kernel-head.txt"
git -C "$SKW" rev-parse HEAD | tee "$BACKUP/seekwave-head.txt"
echo "[*] kernel wrong-owner entries: $(find "$KERNEL" -xdev \( ! -user "$(id -un)" -o ! -group "$(id -gn)" \) -print 2>/dev/null | wc -l)"
echo "[*] seekwave wrong-owner entries: $(find "$SKW" -xdev \( ! -user "$(id -un)" -o ! -group "$(id -gn)" \) -print 2>/dev/null | wc -l)"

echo "[3/10] Apply permanent RK817 clkout platform-ID fix"
if grep -q '"rk817-clkout"' "$CLK_SRC"; then
    echo "[*] rk817-clkout already present."
elif grep -q '"rk817-clk"' "$CLK_SRC"; then
    sed -i 's/"rk817-clk"/"rk817-clkout"/' "$CLK_SRC"
else
    echo "[-] Neither rk817-clk nor rk817-clkout found; refusing blind edit."
    exit 1
fi
grep -n 'rk817-clk' "$CLK_SRC"

echo "[4/10] Restore Seekwave boot-stage 0000:0000 SDIO match"
if grep -Eq '^[[:space:]]*\{[[:space:]]*SDIO_DEVICE\(0[xX]?0*,[[:space:]]*0[xX]?0*\)[[:space:]]*\},' "$SDIO_SRC"; then
    echo "[*] SDIO_DEVICE(0,0) already enabled."
else
    sed -i -E 's@^[[:space:]]*//[[:space:]]*\{[[:space:]]*SDIO_DEVICE\(0[xX]?0*,[[:space:]]*0[xX]?0*\)[[:space:]]*\},@\t{SDIO_DEVICE(0, 0)},@' "$SDIO_SRC"
fi
grep -Eq '^[[:space:]]*\{[[:space:]]*SDIO_DEVICE\(0[xX]?0*,[[:space:]]*0[xX]?0*\)[[:space:]]*\},' "$SDIO_SRC" || { echo "[-] Failed to enable SDIO_DEVICE(0,0)."; exit 1; }
grep -n -A6 -B2 'skw_sdio_ids' "$SDIO_SRC" | head -n 12

echo "[5/10] Preserve full SV6160 identity"
sed -i 's/#define CHIP_DEV_NAME "sv6160lite"/#define CHIP_DEV_NAME "sv6160"/' "$BOOT_SRC"
sed -i 's/static char \*local_chip_id = "SV6160LITE";/static char *local_chip_id = "SV6160";/' "$BOOT_SRC"
grep -nE 'CHIP_DEV_NAME|local_chip_id' "$BOOT_SRC" | head -n 8
grep -q '#define CHIP_DEV_NAME "sv6160"' "$BOOT_SRC" || { echo "[-] Full SV6160 CHIP_DEV_NAME verification failed."; exit 1; }
grep -q 'local_chip_id = "SV6160"' "$BOOT_SRC" || { echo "[-] Full SV6160 local_chip_id verification failed."; exit 1; }

echo "[6/10] Validate running-build kernel configuration"
[ -f "$KERNEL/.config" ] || { echo "[-] Missing $KERNEL/.config; refusing to regenerate config from defconfig."; exit 1; }
grep -q '^CONFIG_COMMON_CLK_RK808=y$' "$KERNEL/.config" || { echo "[-] CONFIG_COMMON_CLK_RK808 is not built-in."; exit 1; }
grep -q '^CONFIG_DRM_PANFROST=y$' "$KERNEL/.config" || { echo "[-] Protected Panfrost config missing."; exit 1; }
grep -q '^# CONFIG_MALI_BIFROST is not set$' "$KERNEL/.config" || { echo "[-] MALI_BIFROST unexpectedly enabled."; exit 1; }
grep -q '^CONFIG_GS_SC7A20=y$' "$KERNEL/.config" || { echo "[-] SC7A20 protected config missing."; exit 1; }
grep -q '^CONFIG_GS_DA223=y$' "$KERNEL/.config" || { echo "[-] DA223 protected config missing."; exit 1; }
MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
JOBS="$(( MEM_KB / 1024 / 1024 / 2 ))"
[ "$JOBS" -lt 1 ] && JOBS=1
CPUS="$(nproc)"
[ "$JOBS" -gt "$CPUS" ] && JOBS="$CPUS"
[ "$JOBS" -gt 8 ] && JOBS=8
echo "[*] build jobs=$JOBS"

echo "[7/10] Incrementally rebuild kernel Image"
make -C "$KERNEL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- WERROR=0 -j"$JOBS" Image
KREL="$(make -s -C "$KERNEL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
echo "[*] kernelrelease=$KREL"
[ "$KREL" = "6.1.172" ] || { echo "[-] Unexpected kernelrelease $KREL; refusing deployment."; exit 1; }
sha256sum "$KERNEL/arch/arm64/boot/Image" | tee "$BACKUP/Image.sha256"

echo "[8/10] Rebuild only the modern Seekwave BSP module"
if [ -f "$KERNEL/Module.symvers" ] && [ -f "$KERNEL/vmlinux" ]; then
    if ! aarch64-linux-gnu-nm "$KERNEL/vmlinux" 2>/dev/null | grep -qE '[[:space:]]skw_start_wifi_service$'; then
        sed -i '/[[:space:]]skw_start_wifi_service[[:space:]]/d' "$KERNEL/Module.symvers"
    fi
    if ! aarch64-linux-gnu-nm "$KERNEL/vmlinux" 2>/dev/null | grep -qE '[[:space:]]skw_stop_wifi_service$'; then
        sed -i '/[[:space:]]skw_stop_wifi_service[[:space:]]/d' "$KERNEL/Module.symvers"
    fi
fi
make -C "$KERNEL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$SKW" clean
make -C "$KERNEL" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$SKW" CONFIG_SEEKWAVE_BSP_DRIVERS=m CONFIG_SKW_NO_CONFIG=y CONFIG_SKW_SDIOHAL=m CONFIG_WLAN_VENDOR_SWT6621S=n CONFIG_SKW_BT=n modules
SKW_KO="$SKW/drivers/seekwaveplatform_lite/skw_sdio_lite.ko"
[ -f "$SKW_KO" ] || { echo "[-] skw_sdio_lite.ko was not produced."; exit 1; }
strings "$SKW_KO" | grep -m1 'vermagic=' || true
sha256sum "$SKW_KO" | tee "$BACKUP/skw_sdio_lite.ko.sha256"

echo "[9/10] Mount verified SD and deploy V5.9"
sudo mkdir -p "$BOOT_MNT" "$ROOT_MNT"
sudo umount "$BOOT_PART" 2>/dev/null || true
sudo umount "$ROOT_PART" 2>/dev/null || true
sudo mount "$ROOT_PART" "$ROOT_MNT"
sudo mount "$BOOT_PART" "$BOOT_MNT"
[ -f "$BOOT_MNT/Image" ] || { echo "[-] $BOOT_MNT/Image missing; refusing deployment."; exit 1; }
[ -d "$ROOT_MNT/lib/modules/$KREL" ] || { echo "[-] Rootfs modules/$KREL missing; refusing deployment."; exit 1; }
cp -a "$BOOT_MNT/Image" "$BACKUP/Image.on-card.before"
if [ -f "$ROOT_MNT/lib/modules/$KREL/updates/c20e-seekwave/skw_sdio_lite.ko" ]; then
    cp -a "$ROOT_MNT/lib/modules/$KREL/updates/c20e-seekwave/skw_sdio_lite.ko" "$BACKUP/skw_sdio_lite.ko.on-card.before"
fi
sudo install -m 0644 "$KERNEL/arch/arm64/boot/Image" "$BOOT_MNT/Image"
sudo install -D -m 0644 "$SKW_KO" "$ROOT_MNT/lib/modules/$KREL/updates/c20e-seekwave/skw_sdio_lite.ko"
if command -v depmod >/dev/null 2>&1; then
    sudo depmod -b "$ROOT_MNT" "$KREL"
fi
sudo install -d -m 0755 "$ROOT_MNT/usr/local/sbin"
sudo tee "$ROOT_MNT/usr/local/sbin/c20e-v5.9-capture" >/dev/null <<'CAPTURE'
#!/bin/sh
OUT=/var/log/c20e-v5.9-sdio-state.log
sleep 15
{
echo "=== C20e V5.9 SDIO capture ==="
date
uname -a
echo
echo "=== deferred devices ==="
cat /sys/kernel/debug/devices_deferred 2>/dev/null || true
echo
echo "=== RK817 clocks ==="
grep -Ei 'rk808|rk817|clkout|32k' /sys/kernel/debug/clk/clk_summary 2>/dev/null || true
echo
echo "=== SDIO functions ==="
for f in /sys/bus/sdio/devices/*; do
    [ -e "$f" ] || continue
    echo "-- $f --"
    cat "$f/vendor" "$f/device" "$f/class" "$f/modalias" 2>/dev/null || true
done
echo
echo "=== modules ==="
cat /proc/modules 2>/dev/null | grep -E 'skw|swt' || true
echo
echo "=== network ==="
ip -br link 2>/dev/null || true
echo
echo "=== filtered dmesg ==="
dmesg | grep -Ei 'rk817-clkout|pwrseq|ff890000|mmc1|sdio|skw|seekwave|sv6160|firmware|chip' || true
} > "$OUT" 2>&1
CAPTURE
sudo chmod 0755 "$ROOT_MNT/usr/local/sbin/c20e-v5.9-capture"
sudo tee "$ROOT_MNT/etc/systemd/system/c20e-v5.9-capture.service" >/dev/null <<'UNIT'
[Unit]
Description=C20e V5.9 SDIO diagnostic capture
After=systemd-modules-load.service c20e-usb-debug.service
Wants=c20e-usb-debug.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-v5.9-capture

[Install]
WantedBy=multi-user.target
UNIT
sudo mkdir -p "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sfn /etc/systemd/system/c20e-v5.9-capture.service "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9-capture.service"

echo "[10/10] Final verification and clean unmount"
echo "[*] deployed Image:"
sudo sha256sum "$BOOT_MNT/Image"
echo "[*] deployed BSP:"
sudo sha256sum "$ROOT_MNT/lib/modules/$KREL/updates/c20e-seekwave/skw_sdio_lite.ko"
echo "[*] modules-load:"
sudo grep -Rns 'skw_sdio_lite' "$ROOT_MNT/etc/modules-load.d" 2>/dev/null || true
echo "[*] extlinux default:"
sudo grep -Ei '^[[:space:]]*default|^[[:space:]]*label' "$BOOT_MNT/extlinux/extlinux.conf" 2>/dev/null || true
sync
sudo umount "$BOOT_MNT"
sudo umount "$ROOT_MNT"

echo
echo "[+] C20e V5.9 deployment complete."
echo "[+] Permanent fixes deployed:"
echo "    1) rk817-clk -> rk817-clkout platform ID"
echo "    2) Seekwave SDIO_DEVICE(0,0) boot-stage match"
echo "[+] Boot diagnostics will be written to /var/log/c20e-v5.9-sdio-state.log"
echo "[+] Host backup: $BACKUP"
echo "[+] Build log: $LOG"
