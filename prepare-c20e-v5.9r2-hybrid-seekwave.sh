#!/usr/bin/env bash
set -Eeuo pipefail

REPO="$HOME/Desktop/workspace/rk3562deb"
TARGET=/dev/sda
KREL=6.1.172
EXPECT_BOOT_PARTUUID='f2e4c648-207d-45f0-b5ad-7886f75e57eb'
EXPECT_ROOT_PARTUUID='c0ffee11-2233-4455-6677-8899aabbccdd'
EXPECT_MODEL='Storage Device'
EXPECT_SIZE='29.1G'
KERNEL="$REPO/src/kernel"
MODERN="$REPO/c20e-thirdparty/seekwave-swt6621s"
OLD_SRC="$REPO/overlay/drivers/net/wireless/ea6621q/skwifi"
OLD_CFG="$REPO/overlay/include/linux/platform_data/skw6160_config.h"
LEGACY="$REPO/c20e-thirdparty/skwifi-sv6160-legacy"
ANALYSIS="$REPO/c20e-analysis"
BACKUP_ROOT="$REPO/c20e-backup"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$ANALYSIS/c20e-v5.9r2-build-$STAMP.log"
BACKUP="$BACKUP_ROOT/v5.9r2-$STAMP"
MNT=/mnt/c20e-v59r2-root

mkdir -p "$ANALYSIS" "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    rc=$?
    set +e
    if mountpoint -q "$MNT"; then sudo umount "$MNT"; fi
    echo "[V5.9r2] exit=$rc"
    echo "[V5.9r2] log=$LOG"
    exit "$rc"
}
trap cleanup EXIT

refuse() { echo "[-] REFUSING: $*"; exit 1; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    refuse "run this script as gwhitlock, not with sudo"
fi

printf '%s\n' '=== C20e V5.9r2: modern SV6160 BSP + legacy Wi-Fi protocol driver ==='
echo "[*] repo=$REPO"
echo "[*] target=$TARGET"
echo "[*] log=$LOG"

echo '[1/10] Host/source preflight'
[[ -d "$REPO" ]] || refuse "repo missing: $REPO"
[[ -d "$KERNEL/.git" ]] || refuse "kernel git tree missing"
[[ -d "$MODERN/.git" ]] || refuse "modern Seekwave tree missing"
[[ -d "$OLD_SRC" ]] || refuse "legacy skwifi source missing"
[[ -f "$OLD_CFG" ]] || refuse "legacy skw6160_config.h missing"
[[ -f "$MODERN/include/linux/platform_data/skw_platform_data.h" ]] || refuse "modern platform-data header missing"
[[ -f "$MODERN/Module.symvers" ]] || refuse "modern Seekwave Module.symvers missing; V5.9r1 build artifacts required"
[[ -f "$MODERN/drivers/seekwaveplatform_lite/skw_sdio_lite.ko" ]] || refuse "modern skw_sdio_lite.ko missing"
KHEAD="$(git -C "$KERNEL" rev-parse HEAD)"
MHEAD="$(git -C "$MODERN" rev-parse HEAD)"
echo "[*] kernel HEAD=$KHEAD"
echo "[*] seekwave HEAD=$MHEAD"
[[ "$KHEAD" == 77168c8d5ab82399f65a80e9f807b50ba37cf483 ]] || refuse "unexpected kernel HEAD"
[[ "$MHEAD" == b1b15016119cb21965fc64dd374e42f46f011bb4 ]] || refuse "unexpected modern Seekwave HEAD"
KR="$(make -s -C "$KERNEL" ARCH=arm64 kernelrelease)"
echo "[*] kernelrelease=$KR"
[[ "$KR" == "$KREL" ]] || refuse "kernelrelease mismatch: $KR"

echo '[2/10] Storage safety checks'
[[ -b "$TARGET" ]] || refuse "$TARGET is not a block device"
ROOTSRC="$(findmnt -n -o SOURCE / || true)"
echo "[*] host root device: $ROOTSRC"
[[ "$ROOTSRC" != "$TARGET"* ]] || refuse "target is host root device"
MODEL="$(lsblk -dn -o MODEL "$TARGET" | sed 's/[[:space:]]*$//')"
SIZE="$(lsblk -dn -o SIZE "$TARGET" | xargs)"
echo "[*] target model='$MODEL' size='$SIZE'"
[[ "$MODEL" == "$EXPECT_MODEL" ]] || refuse "target model mismatch"
[[ "$SIZE" == "$EXPECT_SIZE" ]] || refuse "target size mismatch"
BOOT_UUID="$(sudo blkid -s PARTUUID -o value "${TARGET}3" || true)"
ROOT_UUID="$(sudo blkid -s PARTUUID -o value "${TARGET}4" || true)"
ROOT_LABEL="$(sudo blkid -s LABEL -o value "${TARGET}4" || true)"
echo "[*] boot PARTUUID=$BOOT_UUID"
echo "[*] root PARTUUID=$ROOT_UUID label=$ROOT_LABEL"
[[ "$BOOT_UUID" == "$EXPECT_BOOT_PARTUUID" ]] || refuse "boot PARTUUID mismatch"
[[ "$ROOT_UUID" == "$EXPECT_ROOT_PARTUUID" ]] || refuse "root PARTUUID mismatch"
[[ "$ROOT_LABEL" == rootfs ]] || refuse "root label mismatch"

for p in "${TARGET}"{1,2,3,4}; do
    if findmnt -rn -S "$p" >/dev/null 2>&1; then refuse "$p is already mounted; unmount it first"; fi
done

echo '[3/10] Back up previous hybrid source and prepare legacy Wi-Fi tree'
if [[ -e "$LEGACY" ]]; then
    cp -a "$LEGACY" "$BACKUP/skwifi-sv6160-legacy.previous"
fi
rm -rf "$LEGACY"
cp -a "$OLD_SRC" "$LEGACY"
cp -a "$MODERN/include/linux/platform_data/skw_platform_data.h" "$LEGACY/skw_platform_data.h"
cp -a "$OLD_CFG" "$LEGACY/skw6160_config.h"
chmod -R u+rwX "$LEGACY"

echo '[4/10] Adapt legacy upper driver to modern BSP platform callbacks'
python3 - "$LEGACY" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
h = root / 'skw_core.h'
c = root / 'skw_core.c'
r = root / 'skw_recovery.c'
text = h.read_text()
text = text.replace('extern int skw_start_wifi_service(void);\nextern int skw_stop_wifi_service(void);\n\n', '')
pat = re.compile(r'static inline int skw_wifi_enable\(void\)\n\{\n\treturn skw_start_wifi_service\(\);\n\}\n\nstatic inline int skw_wifi_disable\(void\)\n\{\n\treturn skw_stop_wifi_service\(\);\n\}')
rep = '''static inline int skw_wifi_enable(void *pdata)\n{\n\tstruct sv6160_platform_data *pd = pdata;\n\n\tif (pd && pd->service_start)\n\t\treturn pd->service_start();\n\n\treturn -ENOTSUPP;\n}\n\nstatic inline int skw_wifi_disable(void *pdata)\n{\n\tstruct sv6160_platform_data *pd = pdata;\n\n\tif (pd && pd->service_stop)\n\t\treturn pd->service_stop();\n\n\treturn -ENOTSUPP;\n}'''
text, n = pat.subn(rep, text, count=1)
if n != 1:
    raise SystemExit('failed to patch skw_wifi_enable/disable wrappers')
h.write_text(text)
text = c.read_text()
if text.count('skw_wifi_enable();') != 1:
    raise SystemExit('unexpected skw_wifi_enable call count in skw_core.c')
text = text.replace('skw_wifi_enable();', 'skw_wifi_enable(dev_get_platdata(&pdev->dev));')
if text.count('skw_wifi_disable();') < 1:
    raise SystemExit('no skw_wifi_disable calls found in skw_core.c')
text = text.replace('skw_wifi_disable();', 'skw_wifi_disable(skw->hw_pdata);')
text = text.replace('MODULE_VERSION("1.0.0");', 'MODULE_VERSION("1.0.0-c20e-v5.9r2");')
c.write_text(text)
text = r.read_text()
if text.count('skw_wifi_enable();') != 1:
    raise SystemExit('unexpected skw_wifi_enable call count in skw_recovery.c')
text = text.replace('skw_wifi_enable();', 'skw_wifi_enable(skw->hw_pdata);')
r.write_text(text)
PY

grep -n 'SKW_CMD_VER(SKW_CMD_SET_SPD_ACTION, V2)' "$LEGACY/skw_core.c" || refuse "legacy SPD_ACTION is not V2"
grep -n '\.name = "sv6160_wireless1"' "$LEGACY/skw_core.c" || refuse "legacy platform driver name is not sv6160_wireless1"
grep -n 'struct skw_scan_param' "$LEGACY/skw_cfg80211.h" | head -n 1
if grep -q '^#define CONFIG_SKW_LEGACY_P2P' "$LEGACY/skw6160_config.h"; then refuse "legacy P2P unexpectedly enabled"; fi

echo '[5/10] Build legacy Wi-Fi upper module against kernel 6.1.172 + modern BSP symbols'
JOBS="$(nproc)"
echo "[*] build jobs=$JOBS"
make -C "$KERNEL" M="$LEGACY" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
make -C "$KERNEL" M="$LEGACY" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" \
    CONFIG_WLAN_VENDOR_SEEKWAVE=m \
    CONFIG_SKW_VENDOR=y \
    skw_extra_flags="-I$LEGACY -include $LEGACY/skw6160_config.h -DCONFIG_SEEKWAVE_PLD_RELEASE" \
    skw_extra_symbols="$MODERN/Module.symvers" \
    KCFLAGS='-Wno-error' modules

LEGACY_KO="$LEGACY/skw.ko"
[[ -f "$LEGACY_KO" ]] || refuse "legacy skw.ko was not produced"
VM="$(modinfo -F vermagic "$LEGACY_KO" | awk '{print $1}')"
echo "[*] legacy Wi-Fi vermagic=$(modinfo -F vermagic "$LEGACY_KO")"
[[ "$VM" == "$KREL" ]] || refuse "legacy Wi-Fi vermagic mismatch"
sha256sum "$LEGACY_KO"

echo '[6/10] Mount verified rootfs and back up on-card state'
sudo mkdir -p "$MNT"
sudo mount "${TARGET}4" "$MNT"
[[ -f "$MNT/etc/os-release" ]] || refuse "mounted target does not look like Linux rootfs"
[[ -d "$MNT/lib/modules/$KREL" ]] || refuse "target lacks /lib/modules/$KREL"
mkdir -p "$BACKUP/card"
for f in \
    "$MNT/lib/modules/$KREL/updates/c20e-seekwave/swt6621s_wifi.ko" \
    "$MNT/etc/modules-load.d/c20e-seekwave.conf" \
    "$MNT/etc/modprobe.d/c20e-seekwave.conf" \
    "$MNT/etc/modprobe.d/c20e-disable-modern-swt6621s.conf"; do
    if [[ -f "$f" ]]; then sudo cp -a "$f" "$BACKUP/card/$(basename "$f")"; fi
done

echo '[7/10] Deploy hybrid module and prevent modern upper driver autoload'
sudo mkdir -p "$MNT/lib/modules/$KREL/updates/c20e-seekwave" "$MNT/etc/modules-load.d" "$MNT/etc/modprobe.d"
sudo install -m 0644 "$LEGACY_KO" "$MNT/lib/modules/$KREL/updates/c20e-seekwave/skw.ko"
sudo rm -f "$MNT/lib/modules/$KREL/updates/c20e-seekwave/swt6621s_wifi.ko"
printf '%s\n' 'skw_sdio_lite' 'skw' | sudo tee "$MNT/etc/modules-load.d/c20e-seekwave.conf" >/dev/null
printf '%s\n' 'softdep skw pre: skw_sdio_lite' | sudo tee "$MNT/etc/modprobe.d/c20e-seekwave.conf" >/dev/null
printf '%s\n' 'blacklist swt6621s_wifi' | sudo tee "$MNT/etc/modprobe.d/c20e-disable-modern-swt6621s.conf" >/dev/null
sudo depmod -b "$MNT" "$KREL"

echo '[8/10] Keep userspace Wi-Fi managers off for first protocol test'
sudo systemctl --root="$MNT" disable NetworkManager.service >/dev/null 2>&1 || true
sudo systemctl --root="$MNT" disable wpa_supplicant.service >/dev/null 2>&1 || true
sudo rm -f "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9r1-capture.service"

echo '[9/10] Install V5.9r2 idle-state capture service'
sudo mkdir -p "$MNT/usr/local/sbin" "$MNT/etc/systemd/system/multi-user.target.wants"
sudo tee "$MNT/usr/local/sbin/c20e-v59r2-capture.sh" >/dev/null <<'CAPTURE'
#!/bin/sh
sleep 25
OUT=/var/log/c20e-v5.9r2-hybrid-wifi-state.log
{
  echo '=== C20e V5.9r2 hybrid Wi-Fi state ==='
  date
  uname -a
  echo '--- modules ---'
  lsmod | grep -E '(^skw|seekwave)' || true
  echo '--- platform binding ---'
  for d in /sys/bus/platform/devices/sv6160_wireless1*; do
    [ -e "$d" ] || continue
    echo "device=$d"
    readlink "$d/driver" || true
  done
  echo '--- links ---'
  ip -br link || true
  echo '--- iw dev ---'
  iw dev || true
  echo '--- rfkill ---'
  rfkill list || true
  echo '--- NetworkManager/wpa_supplicant ---'
  systemctl is-enabled NetworkManager.service 2>/dev/null || true
  systemctl is-active NetworkManager.service 2>/dev/null || true
  systemctl is-enabled wpa_supplicant.service 2>/dev/null || true
  systemctl is-active wpa_supplicant.service 2>/dev/null || true
  echo '--- seekwave dmesg ---'
  dmesg | grep -Ei 'SKW|Seekwave|SV6160|WIFIREADY|BSPASSERT|mmc1|ff890000' | tail -n 300 || true
} > "$OUT" 2>&1
CAPTURE
sudo chmod 0755 "$MNT/usr/local/sbin/c20e-v59r2-capture.sh"
sudo tee "$MNT/etc/systemd/system/c20e-v5.9r2-capture.service" >/dev/null <<'UNIT'
[Unit]
Description=C20e V5.9r2 hybrid Wi-Fi capture
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-v59r2-capture.sh

[Install]
WantedBy=multi-user.target
UNIT
sudo ln -sfn ../c20e-v5.9r2-capture.service "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9r2-capture.service"

echo '[10/10] Final verification and clean unmount'
echo '[*] deployed legacy Wi-Fi:'
sha256sum "$LEGACY_KO"
sudo sha256sum "$MNT/lib/modules/$KREL/updates/c20e-seekwave/skw.ko"
echo '[*] retained modern BSP:'
sudo modinfo -b "$MNT" -F filename skw_sdio_lite || true
echo '[*] modules-load:'
sudo cat "$MNT/etc/modules-load.d/c20e-seekwave.conf"
echo '[*] modprobe policy:'
sudo cat "$MNT/etc/modprobe.d/c20e-seekwave.conf"
sudo cat "$MNT/etc/modprobe.d/c20e-disable-modern-swt6621s.conf"
echo '[*] capture service:'
readlink "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.9r2-capture.service"
sudo sync
sudo umount "$MNT"

echo
echo '[+] C20e V5.9r2 hybrid deployment complete.'
echo '[+] Modern skw_sdio_lite BSP retained.'
echo '[+] Legacy EA6621Q/SV6160 skwifi upper protocol driver deployed as skw.ko.'
echo '[+] Legacy driver uses the modern BSP platform-data layout and service callbacks.'
echo '[+] NetworkManager and wpa_supplicant are disabled for the first idle/scan test.'
echo '[+] Modern swt6621s_wifi is blacklisted and removed from the C20e updates directory.'
echo '[+] No kernel, DTB, display, camera, bootchain, or boot partition files were modified.'
echo '[+] Boot diagnostics will be written to /var/log/c20e-v5.9r2-hybrid-wifi-state.log'
echo "[+] Host backup: $BACKUP"
echo "[+] Build log: $LOG"
