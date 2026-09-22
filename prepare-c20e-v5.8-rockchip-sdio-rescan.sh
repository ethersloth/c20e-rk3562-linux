#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
DEV="${2:-/dev/sda}"
ROOTDEV="${DEV}4"
BOOTDEV="${DEV}3"
MNT="/mnt/c20e-v5.8"
BOOT="$MNT/boot"

K="$REPO/src/kernel"
IMG="$K/arch/arm64/boot/Image"
PIN="b1b15016119cb21965fc64dd374e42f46f011bb4"
SRCROOT="$REPO/c20e-thirdparty"
SRC="$SRCROOT/seekwave-swt6621s"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-analysis/c20e-v5.8-rockchip-rescan-$STAMP"
LOG="$REPORT/full.log"

RUN_USER="${SUDO_USER:-root}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
[[ -n "$RUN_HOME" ]] || RUN_HOME="/root"

mkdir -p "$REPORT/backups"
exec > >(tee -a "$LOG") 2>&1

CARD_MOUNTED=0
CARD_MUTATED=0
KREL=""

runu() {
    if [[ "$RUN_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$RUN_USER" env HOME="$RUN_HOME" "$@"
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rc=$?
    set +e

    if [[ $rc -ne 0 && $CARD_MUTATED -eq 1 && $CARD_MOUNTED -eq 1 ]]; then
        echo
        echo "Failure after SD mutation; restoring card-side backups."
        [[ -f "$REPORT/backups/skw_sdio_lite.ko.before-v5.8" ]] && cp -f "$REPORT/backups/skw_sdio_lite.ko.before-v5.8" "$MNT/lib/modules/$KREL/updates/c20e-seekwave/skw_sdio_lite.ko"
        [[ -f "$REPORT/backups/swt6621s_wifi.ko.before-v5.8" ]] && cp -f "$REPORT/backups/swt6621s_wifi.ko.before-v5.8" "$MNT/lib/modules/$KREL/updates/c20e-seekwave/swt6621s_wifi.ko"
        [[ -f "$REPORT/backups/c20e-seekwave-v5.7.conf.before-v5.8" ]] && cp -f "$REPORT/backups/c20e-seekwave-v5.7.conf.before-v5.8" "$MNT/etc/modules-load.d/c20e-seekwave-v5.7.conf"
        [[ -f "$REPORT/backups/extlinux.conf.before-v5.8" ]] && cp -f "$REPORT/backups/extlinux.conf.before-v5.8" "$BOOT/extlinux/extlinux.conf"
        rm -f "$MNT/etc/systemd/system/c20e-v5.8-capture.service"
        rm -f "$MNT/usr/local/sbin/c20e-v5.8-capture.sh"
        rm -f "$MNT/etc/systemd/system/multi-user.target.wants/c20e-v5.8-capture.service"
        [[ -n "$KREL" ]] && depmod -b "$MNT" "$KREL" >/dev/null 2>&1 || true
        sync
    fi

    mountpoint -q "$BOOT" && umount "$BOOT"
    mountpoint -q "$MNT" && umount "$MNT"
    rmdir "$MNT" 2>/dev/null || true

    chown -R "$RUN_USER:$RUN_GROUP" "$REPORT" "$SRCROOT" 2>/dev/null || true
    echo "[$(date -Is)] EXIT rc=$rc"
    exit "$rc"
}
trap cleanup EXIT

echo "=== C20e V5.8 Rockchip SDIO rescan isolation ==="
echo "Time:       $(date -Is)"
echo "Repo:       $REPO"
echo "SD target:  $DEV"
echo "Kernel:     $K"
echo "Driver pin: retro98boy/seekwave-swt6621s@$PIN"
echo

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -d "$K" && -f "$K/.config" && -s "$IMG" ]] || die "Kernel tree/config/Image missing."
[[ -b "$DEV" && -b "$ROOTDEV" && -b "$BOOTDEV" ]] || die "Expected $DEV with partitions 3 and 4."

for cmd in git make python3 aarch64-linux-gnu-gcc aarch64-linux-gnu-nm e2fsck fsck.vfat depmod modinfo sha256sum blkid lsblk; do
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
    die "Target card has mounted partitions."
fi

grep -q '^# CONFIG_SEEKWAVE_BSP_DRIVERS is not set' "$K/.config" || die "Old in-tree Seekwave BSP is not disabled."
grep -q '^# CONFIG_U_SERIAL_CONSOLE is not set' "$K/.config" || die "U_SERIAL_CONSOLE unexpectedly enabled."

KREL="$(runu env ARCH=arm64 make -s -C "$K" kernelrelease)"
[[ "$KREL" == "6.1.172" ]] || die "Unexpected kernel release '$KREL'."

echo "===== 1/11 verify Rockchip rescan API is available ====="
aarch64-linux-gnu-nm "$K/vmlinux" | grep -E '[[:space:]]rockchip_wifi_set_carddetect$' | tee "$REPORT/rockchip-carddetect-symbol.txt"
[[ -s "$REPORT/rockchip-carddetect-symbol.txt" ]] || die "rockchip_wifi_set_carddetect is absent from vmlinux."

if [[ -f "$K/Module.symvers" ]]; then
    grep -E '[[:space:]]rockchip_wifi_set_carddetect[[:space:]]' "$K/Module.symvers" | tee "$REPORT/rockchip-carddetect-export.txt" || true
fi
[[ -s "$REPORT/rockchip-carddetect-export.txt" ]] || die "rockchip_wifi_set_carddetect is not exported in Module.symvers."

echo
echo "===== 2/11 reset pinned modern Seekwave source ====="
mkdir -p "$SRCROOT"
chown -R "$RUN_USER:$RUN_GROUP" "$SRCROOT"

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

echo
echo "===== 3/11 apply C20e full-SV6160 + GCC16 + Wi-Fi-only + Rockchip-rescan patches ====="
runu python3 - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

p = src / "drivers/seekwaveplatform_lite/skwutil/skw_boot.c"
s = p.read_text()
a = '#define CHIP_DEV_NAME "sv6160lite"'
b = '#define CHIP_DEV_NAME "sv6160"'
assert a in s, "CHIP_DEV_NAME anchor missing"
s = s.replace(a, b, 1)
a = 'static char *local_chip_id = "SV6160LITE";'
b = 'static char *local_chip_id = "SV6160";'
assert a in s, "local_chip_id anchor missing"
p.write_text(s.replace(a, b, 1))

p = src / "drivers/swt6621s_wifi/skw_util.h"
s = p.read_text()
a = '#define SKW_ZALLOC(s, f)             ((s) ? kzalloc(s, f) : NULL)'
b = '#define SKW_ZALLOC(s, f)             (((s) != 0) ? kzalloc((s), (f)) : NULL)'
assert a in s, "SKW_ZALLOC anchor missing"
p.write_text(s.replace(a, b, 1))

p = src / "drivers/seekwaveplatform_lite/skwutil/skw_btlog.h"
s = p.read_text()
a = '//#define SKWBT_LOG_PORT_EN 0'
b = '#define SKWBT_LOG_PORT_EN 0'
assert a in s, "SKWBT_LOG_PORT_EN anchor missing"
p.write_text(s.replace(a, b, 1))

p = src / "drivers/seekwaveplatform_lite/sdio/skw_sdio_host.c"
s = p.read_text()
inc = '#include "../skwutil/boot_config.h"\n'
assert inc in s, "boot_config include anchor missing"
s = s.replace(inc, inc + 'extern int rockchip_wifi_set_carddetect(int val);\n', 1)

old = '#else\n\tpr_info("%s: no need skw self scan!!\\\\n", __func__);\n#endif'
new = '''#else
\t/*
\t * C20e/RK3562: keep power sequencing in DT/mmc-pwrseq, but ask
\t * Rockchip's MMC layer to perform the SDIO card-detect rescan.
\t */
\tpr_info("%s: C20e request Rockchip SDIO card-detect rescan\\\\n", __func__);
\tmsleep(250);
\tret = rockchip_wifi_set_carddetect(1);
\tpr_info("%s: rockchip_wifi_set_carddetect ret=%d\\\\n", __func__, ret);
#endif'''
assert old in s, "no-self-scan branch anchor missing"
p.write_text(s.replace(old, new, 1))
PY

runu git -C "$SRC" diff --check
runu git -C "$SRC" diff > "$REPORT/seekwave-v5.8.patch"

grep -q 'C20e request Rockchip SDIO card-detect rescan' "$SRC/drivers/seekwaveplatform_lite/sdio/skw_sdio_host.c" || die "Rockchip rescan patch missing."
grep -q '#define CHIP_DEV_NAME "sv6160"' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_boot.c" || die "SV6160 adaptation missing."
grep -Fxq '#define SKWBT_LOG_PORT_EN 0' "$SRC/drivers/seekwaveplatform_lite/skwutil/skw_btlog.h" || die "BT log disable missing."

echo
echo "===== 4/11 build modern BSP + Wi-Fi modules against current V5.7r6 kernel ====="
CROSS="$(command -v aarch64-linux-gnu-gcc)"
CROSS="${CROSS%gcc}"

runu env ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" \
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

grep -q "vermagic:.*$KREL" "$REPORT/seekwave-modinfo.txt" || die "Module vermagic mismatch."

echo
echo "===== 5/11 repair filesystems after prior hard power-off ====="
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
echo "===== 6/11 mount and validate C20e card ====="
mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
mkdir -p "$BOOT"
mount "$BOOTDEV" "$BOOT"
CARD_MOUNTED=1

[[ "$(cat "$MNT/etc/hostname" 2>/dev/null)" == "gregdebtab" ]] || die "Unexpected rootfs hostname."
[[ -e "$MNT/var/lib/c20e/firstboot-complete" ]] || die "firstboot-complete marker missing."
[[ -f "$BOOT/extlinux/extlinux.conf" ]] || die "extlinux.conf missing."

cmp -s "$IMG" "$BOOT/Image" || die "Card Image does not match the current V5.7r6 build Image."

MODDIR="$MNT/lib/modules/$KREL/updates/c20e-seekwave"
mkdir -p "$MODDIR"

cp -a "$BOOT/extlinux/extlinux.conf" "$REPORT/backups/extlinux.conf.before-v5.8"
[[ -f "$MODDIR/skw_sdio_lite.ko" ]] && cp -a "$MODDIR/skw_sdio_lite.ko" "$REPORT/backups/skw_sdio_lite.ko.before-v5.8"
[[ -f "$MODDIR/swt6621s_wifi.ko" ]] && cp -a "$MODDIR/swt6621s_wifi.ko" "$REPORT/backups/swt6621s_wifi.ko.before-v5.8"
[[ -f "$MNT/etc/modules-load.d/c20e-seekwave-v5.7.conf" ]] && cp -a "$MNT/etc/modules-load.d/c20e-seekwave-v5.7.conf" "$REPORT/backups/c20e-seekwave-v5.7.conf.before-v5.8"

echo
echo "===== 7/11 deploy V5.8 rescan-enabled modules ====="
CARD_MUTATED=1

install -m 0644 "$SDIOKO" "$MODDIR/skw_sdio_lite.ko"
install -m 0644 "$WIFIKO" "$MODDIR/swt6621s_wifi.ko"
depmod -b "$MNT" "$KREL"

echo "skw_sdio_lite" > "$MNT/etc/modules-load.d/c20e-seekwave-v5.7.conf"

echo
echo "===== 8/11 force headless diagnostic boot ====="
systemctl --root="$MNT" set-default multi-user.target >/dev/null
systemctl --root="$MNT" disable lightdm.service >/dev/null 2>&1 || true
systemctl --root="$MNT" disable bluetooth.service >/dev/null 2>&1 || true
systemctl --root="$MNT" enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl --root="$MNT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true

python3 -c 'from pathlib import Path; import re; p=Path("'"$BOOT"'/extlinux/extlinux.conf"); s=p.read_text(); s2,n=re.subn(r"(?m)^default\s+\S+\s*$","default linux-debug",s,count=1); assert n==1, "default label missing"; p.write_text(s2)'

echo
echo "===== 9/11 install automatic post-boot state capture ====="
install -d -m 0755 "$MNT/usr/local/sbin"

cat > "$MNT/usr/local/sbin/c20e-v5.8-capture.sh" <<'EOS'
#!/bin/sh
OUT=/var/log/c20e-v5.8-sdio-state.log
exec >>"$OUT" 2>&1
echo "===== C20e V5.8 capture start ====="
date -Is
uname -a
echo
echo "--- modules ---"
cat /proc/modules
echo
echo "--- SDIO devices ---"
find /sys/bus/sdio/devices -maxdepth 2 -print 2>/dev/null
echo
echo "--- MMC hosts ---"
find /sys/class/mmc_host -maxdepth 3 -print 2>/dev/null
echo
echo "--- network links ---"
ip -br link 2>/dev/null || true
echo
echo "--- rfkill ---"
rfkill list 2>/dev/null || true
echo
echo "--- failed units ---"
systemctl --failed --no-pager 2>/dev/null || true
echo
echo "--- dmesg snapshot 1 ---"
dmesg
sleep 10
echo
echo "===== snapshot 2 ====="
date -Is
echo "--- modules ---"
cat /proc/modules
echo "--- SDIO devices ---"
find /sys/bus/sdio/devices -maxdepth 2 -print 2>/dev/null
echo "--- network links ---"
ip -br link 2>/dev/null || true
echo "--- dmesg snapshot 2 ---"
dmesg
sync
EOS
chmod 0755 "$MNT/usr/local/sbin/c20e-v5.8-capture.sh"

cat > "$MNT/etc/systemd/system/c20e-v5.8-capture.service" <<'EOS'
[Unit]
Description=C20e V5.8 SDIO diagnostic capture
After=multi-user.target c20e-usb-debug.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-v5.8-capture.sh
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOS

systemctl --root="$MNT" enable c20e-v5.8-capture.service >/dev/null

echo
echo "===== 10/11 final validation ====="
sha256sum "$BOOT/Image" "$BOOT/rk3562.dtb" | tee "$REPORT/boot-hashes.txt"
sha256sum "$MODDIR/skw_sdio_lite.ko" "$MODDIR/swt6621s_wifi.ko" | tee "$REPORT/installed-modules.sha256"
cat "$MNT/etc/modules-load.d/c20e-seekwave-v5.7.conf" | tee "$REPORT/modules-load-final.txt"
readlink "$MNT/etc/systemd/system/default.target" | tee "$REPORT/default-target.txt"
grep -E '^(default |label |[[:space:]]+append )' "$BOOT/extlinux/extlinux.conf" | tee "$REPORT/extlinux-summary.txt"
find "$MNT/etc/systemd/system" -maxdepth 3 -type l \( -name 'c20e-usb-debug.service' -o -name 'serial-getty@ttyGS0.service' -o -name 'c20e-v5.8-capture.service' -o -name 'lightdm.service' \) -printf '%p -> %l\n' | tee "$REPORT/systemd-links.txt"

echo
echo "===== 11/11 sync, unmount, package report ====="
sync
umount "$BOOT"
umount "$MNT"
CARD_MOUNTED=0
CARD_MUTATED=0
rmdir "$MNT" 2>/dev/null || true

trap - EXIT

tar -C "$REPO/c20e-analysis" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" | tee "$REPORT.tar.gz.sha256"

chown -R "$RUN_USER:$RUN_GROUP" "$REPORT" "$REPORT.tar.gz" "$REPORT.tar.gz.sha256" "$SRCROOT" 2>/dev/null || true

echo
echo "PASS: C20e V5.8 Rockchip SDIO rescan test prepared."
echo "  - kernel Image/DTB unchanged"
echo "  - modern Seekwave BSP now requests Rockchip SDIO card-detect rescan"
echo "  - only skw_sdio_lite auto-loads"
echo "  - swt6621s_wifi is installed but held back"
echo "  - LightDM disabled; multi-user target selected"
echo "  - USB ACM debug + ttyGS0 getty enabled"
echo "  - automatic /var/log/c20e-v5.8-sdio-state.log capture installed"
echo
echo "Report: $REPORT.tar.gz"
echo "SHA256: $REPORT.tar.gz.sha256"
echo
echo "Review this report before booting."
