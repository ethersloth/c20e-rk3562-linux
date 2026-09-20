#!/usr/bin/env bash
# Deploy a freshly built kernel + DTB to a RUNNING C20e over the network.
#
# The card's FAT boot partition is auto-mounted on the tablet by udisks, owned
# by the login user, so Image and rk3562.dtb can be replaced without sudo and
# without pulling the card. That turns a kernel test from a card-shuffle into
# one command plus a reboot.
#
# Safe because CONFIG_MODVERSIONS is not set: module loading checks vermagic
# only, and UTS_RELEASE stays "6.1.172" across rebuilds, so the out-of-tree
# Seekwave modules already installed on the card keep loading. If the kernel
# VERSION ever changes, use the card path (deploy-c20e-sd.sh +
# install-c20e-hybrid-seekwave.sh) instead, or Wi-Fi and Bluetooth will vanish.
#
# Every overwrite is backed up on the tablet and verified by checksum.
#
# Usage: ./deploy-c20e-ssh.sh [user@host]
set -Eeuo pipefail

TARGET="${1:-gwhitlock@10.255.254.22}"
KEY="${C20E_SSH_KEY:-$HOME/.ssh/c20e_key}"
REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8)
SCP=(scp -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no)

die(){ echo "ERROR: $*" >&2; exit 1; }

IMAGE="$REPO/out/Image"; DTB="$REPO/out/rk3562.dtb"
[[ -f "$IMAGE" ]] || IMAGE="$REPO/src/kernel/arch/arm64/boot/Image"
[[ -f "$DTB"   ]] || DTB="$REPO/src/kernel/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10.dtb"
[[ -f "$IMAGE" ]] || die "no kernel Image found (run ./build.sh extboot)"
[[ -f "$DTB"   ]] || die "no DTB found (run ./build.sh extboot)"
[[ -f "$KEY"   ]] || die "missing ssh key $KEY"

echo "[*] target : $TARGET"
echo "[*] Image  : $IMAGE ($(stat -c%s "$IMAGE") bytes)"
echo "[*] DTB    : $DTB ($(stat -c%s "$DTB") bytes)"

BOOT="$("${SSH[@]}" "$TARGET" 'mount | awk "/vfat/ {print \$3; exit}"' 2>/dev/null || true)"
[[ -n "$BOOT" ]] || die "no vfat boot partition mounted on the tablet"
echo "[*] boot mount on tablet: $BOOT"

"${SSH[@]}" "$TARGET" "[ -w '$BOOT' ]" || die "$BOOT is not writable by $TARGET (needs the udisks automount)"

TS="$(date +%Y%m%d-%H%M%S)"
echo "[*] backing up current Image/rk3562.dtb as *.before-ssh-deploy-$TS"
"${SSH[@]}" "$TARGET" "cp -a '$BOOT/Image' '$BOOT/Image.before-ssh-deploy-$TS' 2>/dev/null; \
                       cp -a '$BOOT/rk3562.dtb' '$BOOT/rk3562.dtb.before-ssh-deploy-$TS' 2>/dev/null; true"

"${SCP[@]}" "$IMAGE" "$TARGET:$BOOT/Image"      >/dev/null || die "copying Image failed"
"${SCP[@]}" "$DTB"   "$TARGET:$BOOT/rk3562.dtb" >/dev/null || die "copying DTB failed"
"${SSH[@]}" "$TARGET" "sync"

L_IMG=$(sha256sum "$IMAGE" | cut -d' ' -f1)
L_DTB=$(sha256sum "$DTB"   | cut -d' ' -f1)
R_IMG=$("${SSH[@]}" "$TARGET" "sha256sum '$BOOT/Image'      | cut -d' ' -f1")
R_DTB=$("${SSH[@]}" "$TARGET" "sha256sum '$BOOT/rk3562.dtb' | cut -d' ' -f1")
[[ "$L_IMG" == "$R_IMG" ]] || die "Image checksum mismatch after copy"
[[ "$L_DTB" == "$R_DTB" ]] || die "DTB checksum mismatch after copy"

echo "[+] verified: Image ${L_IMG:0:12}  DTB ${L_DTB:0:12}"
echo
echo "SUCCESS - reboot the tablet to run the new kernel:"
echo "  ssh -i $KEY $TARGET 'sudo reboot'"
echo "Recovery if it will not boot: put the card in the laptop and restore"
echo "  $BOOT/Image.before-ssh-deploy-$TS"
