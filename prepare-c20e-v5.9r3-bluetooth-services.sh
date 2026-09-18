#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${RKDEBIAN_REPO:-$HOME/Desktop/workspace/rk3562deb}"
TARGET="${1:-/dev/sda}"
KREL=6.1.172
EXPECT_MODEL='Storage Device'
EXPECT_SIZE='29.1G'
EXPECT_BOOT_PARTUUID='f2e4c648-207d-45f0-b5ad-7886f75e57eb'
EXPECT_ROOT_PARTUUID='c0ffee11-2233-4455-6677-8899aabbccdd'
EXPECT_KERNEL_COMMIT='77168c8d5ab82399f65a80e9f807b50ba37cf483'
EXPECT_SEEKWAVE_COMMIT='b1b15016119cb21965fc64dd374e42f46f011bb4'
KERNEL="$REPO/src/kernel"
MODERN="$REPO/c20e-thirdparty/seekwave-swt6621s"
BT_SRC="$MODERN/drivers/swtbt4l"
PLATFORM_HEADER="$MODERN/include/linux/platform_data/skw_platform_data.h"
MNT=/mnt/c20e-v59r3
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$REPO/c20e-backup/v5.9r3-bluetooth-services-$STAMP"
LOG="$REPO/c20e-analysis/v5.9r3-bluetooth-services-$STAMP.log"
MOUNTED=0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    if (( MOUNTED )); then
        sudo sync || true
        sudo umount "$MNT" || true
    fi
    printf '[V5.9r3] exit=%d\n[V5.9r3] log=%s\n' "$exit_code" "$LOG"
}
trap cleanup EXIT

mkdir -p "$(dirname "$LOG")" "$BACKUP"
exec > >(tee "$LOG") 2>&1

printf '%s\n' '=== C20e V5.9r3: Bluetooth upper module and service repairs ==='
printf 'Target: %s\n' "$TARGET"

[[ -b "$TARGET" ]] || die "target is not a block device: $TARGET"
[[ "$(lsblk -dnro TRAN "$TARGET" 2>/dev/null)" == usb ]] || die "$TARGET is not reported as USB"
[[ "$(lsblk -dno MODEL "$TARGET" 2>/dev/null | xargs)" == "$EXPECT_MODEL" ]] || die "unexpected target model"
[[ "$(lsblk -dno SIZE "$TARGET" 2>/dev/null | xargs)" == "$EXPECT_SIZE" ]] || die "unexpected target size"
[[ -b "${TARGET}3" ]] || die "boot partition is missing: ${TARGET}3"
[[ -b "${TARGET}4" ]] || die "root partition is missing: ${TARGET}4"
[[ "$(lsblk -dnro PARTUUID "${TARGET}3")" == "$EXPECT_BOOT_PARTUUID" ]] || die "unexpected boot partition identity"
[[ "$(lsblk -dnro PARTUUID "${TARGET}4")" == "$EXPECT_ROOT_PARTUUID" ]] || die "unexpected root partition identity"
[[ "$(lsblk -dnro FSTYPE "${TARGET}4")" == ext4 ]] || die "${TARGET}4 is not ext4"
[[ "$(git -C "$KERNEL" rev-parse HEAD)" == "$EXPECT_KERNEL_COMMIT" ]] || die "unexpected kernel source commit"
[[ "$(git -C "$MODERN" rev-parse HEAD)" == "$EXPECT_SEEKWAVE_COMMIT" ]] || die "unexpected Seekwave source commit"
[[ -f "$MODERN/Module.symvers" ]] || die "modern BSP Module.symvers is missing"
[[ -f "$PLATFORM_HEADER" ]] || die "modern platform-data header is missing"

echo '[1/5] Build modern Bluetooth upper module against the V5.9r2 BSP contract'
make -C "$KERNEL" M="$BT_SRC" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
make -C "$KERNEL" M="$BT_SRC" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
    CONFIG_SKW_BT=m \
    skw_extra_flags="-I$MODERN/include/linux -I$MODERN/include/linux/platform_data -include linux/types.h -include linux/dma-mapping.h -include linux/scatterlist.h -include $PLATFORM_HEADER -DCONFIG_SEEKWAVE_PLD_RELEASE" \
    skw_extra_symbols="$MODERN/Module.symvers" \
    KCFLAGS='-Wno-error' modules

BT_KO="$BT_SRC/skwbt.ko"
[[ -f "$BT_KO" ]] || die "Bluetooth module was not produced"
[[ "$(modinfo -F vermagic "$BT_KO" | awk '{print $1}')" == "$KREL" ]] || die "Bluetooth module vermagic mismatch"
if aarch64-linux-gnu-nm -u "$BT_KO" | awk '{print $2}' | grep -Eq '^(skw_|sv6160)'; then
    die "Bluetooth module has unresolved Seekwave symbols"
fi
sha256sum "$BT_KO"

echo '[2/5] Mount and verify the V5.9r2 root filesystem'
sudo mkdir -p "$MNT"
sudo mount "${TARGET}4" "$MNT"
MOUNTED=1
[[ -f "$MNT/etc/os-release" ]] || die "target does not look like a Linux root filesystem"
[[ -d "$MNT/lib/modules/$KREL" ]] || die "target lacks kernel modules for $KREL"
[[ "$(sudo modinfo -b "$MNT" -k "$KREL" -F version skw 2>/dev/null)" == 1.0.0-c20e-v5.9r2 ]] || die "target is not the V5.9r2 hybrid Wi-Fi installation"
sudo modinfo -b "$MNT" -k "$KREL" skw_sdio_lite >/dev/null 2>&1 || die "target lacks skw_sdio_lite"

echo '[3/5] Back up service configuration and install skwbt.ko'
for file in \
    "$MNT/lib/modules/$KREL/updates/c20e-seekwave/skwbt.ko" \
    "$MNT/etc/modules-load.d/skwbt.conf" \
    "$MNT/etc/modprobe.d/c20e-skwbt.conf" \
    "$MNT/etc/systemd/system/rk-power-tune.service.d/c20e-ordering.conf"; do
    if sudo test -e "$file"; then
        sudo cp -a "$file" "$BACKUP/$(basename "$file").before"
    fi
done
sudo install -D -m 0644 "$BT_KO" "$MNT/lib/modules/$KREL/updates/c20e-seekwave/skwbt.ko"
printf '%s\n' skwbt | sudo tee "$MNT/etc/modules-load.d/skwbt.conf" >/dev/null
printf '%s\n' 'options skwbt firmware_dir=seekwave' | sudo tee "$MNT/etc/modprobe.d/c20e-skwbt.conf" >/dev/null
sudo depmod -b "$MNT" "$KREL"

echo '[4/5] Enable Bluetooth and remove the power-service ordering cycle'
sudo mkdir -p "$MNT/etc/systemd/system/rk-power-tune.service.d"
sudo tee "$MNT/etc/systemd/system/rk-power-tune.service.d/c20e-ordering.conf" >/dev/null <<'UNIT'
[Unit]
# The base unit's Before=display-manager.service closes a multi-user.target cycle.
Before=
UNIT
sudo systemctl --root="$MNT" enable bluetooth.service
sudo systemctl --root="$MNT" enable rk-power-tune.service rk-power-profile-sync.service

echo '[5/5] Validate installed module and service state'
sudo modinfo -b "$MNT" -k "$KREL" skwbt
[[ "$(sudo modinfo -b "$MNT" -k "$KREL" -F vermagic skwbt | awk '{print $1}')" == "$KREL" ]] || die "installed Bluetooth module vermagic mismatch"
sudo systemctl --root="$MNT" is-enabled bluetooth.service
sudo systemctl --root="$MNT" is-enabled rk-power-tune.service
sudo systemctl --root="$MNT" is-enabled rk-power-profile-sync.service
sudo cat "$MNT/etc/systemd/system/rk-power-tune.service.d/c20e-ordering.conf"

echo
echo '[+] V5.9r3 offline deployment complete.'
echo '[+] Installed only the modern skwbt upper module and service configuration.'
echo '[+] Existing skw_sdio_lite.ko and skw.ko were not replaced.'
echo '[+] Kernel, DTB, bootloader, and boot partition were not modified.'
echo '[+] Reboot, then run scripts/qualify-hardware.sh to validate Bluetooth and boot ordering.'