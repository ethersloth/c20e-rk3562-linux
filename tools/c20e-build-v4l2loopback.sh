#!/usr/bin/env bash
# Build v4l2loopback for the C20e kernel, ON THE LAPTOP (cross-compiled, like the
# Seekwave Wi-Fi/Bluetooth modules).
#
#     ./c20e-build-v4l2loopback.sh                      build into out/
#     ./c20e-build-v4l2loopback.sh --capture prebuilt/camera
#
# WHY this module is needed: the tablet's ISP capture node (/dev/video22, driver
# rkisp_v8) is a MULTIPLANAR V4L2 device, and the userspace that matters refuses
# those -- Qt Multimedia's ffmpeg backend wants single-planar V4L2, PipeWire's
# V4L2 monitor publishes no camera for a multiplanar node, and libcamera has a
# pipeline handler for the mainline rkisp1 driver but not this vendor one. So
# applications report "no camera" even though the sensor and ISP work. The
# loopback gives one ordinary single-planar device, fed by c20e-camera-bridge,
# which Chrome, Firefox, Cheese, GNOME Snapshot and OBS all accept.
#
# Rebuild this whenever the kernel VERSION changes: the module is checked against
# vermagic (CONFIG_MODVERSIONS is off), so it loads across kernel rebuilds only
# while UTS_RELEASE is unchanged.
set -Eeuo pipefail

URL="https://github.com/umlaeute/v4l2loopback.git"
REV="v0.15.4"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
KERNEL="${C20E_KERNEL:-$REPO/src/kernel}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WORK="$REPO/out/v4l2loopback"
CAPTURE=""

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[v4l2loopback] $*"; }

[[ ${1:-} == --capture ]] && { CAPTURE="${2:?--capture needs a directory}"; shift 2; }
[[ -f "$KERNEL/.config" ]] || die "no configured kernel at $KERNEL (run ./build.sh extboot first)"
[[ -f "$KERNEL/Module.symvers" ]] || die "$KERNEL has not been built (no Module.symvers)"
command -v "${CROSS}gcc" >/dev/null || die "missing ${CROSS}gcc"

KREL="$(make -s -C "$KERNEL" ARCH=arm64 kernelrelease)"
say "kernel $KREL, source $REV"

if [[ -d $WORK/.git ]]; then git -C "$WORK" fetch -q --tags origin || true
else rm -rf "$WORK"; git clone -q "$URL" "$WORK"; fi
git -C "$WORK" checkout -q "$REV"
git -C "$WORK" reset -q --hard "$REV"

make -C "$KERNEL" M="$WORK" ARCH=arm64 CROSS_COMPILE="$CROSS" clean >/dev/null 2>&1 || true
make -j"$(nproc)" -C "$KERNEL" M="$WORK" ARCH=arm64 CROSS_COMPILE="$CROSS" modules >/dev/null
[[ -f "$WORK/v4l2loopback.ko" ]] || die "build produced no module"

VM="$(modinfo "$WORK/v4l2loopback.ko" | awk -F': +' '/^vermagic/{print $2}')"
[[ "$VM" == "$KREL"* ]] || die "module vermagic '$VM' does not match kernel $KREL"
say "built $WORK/v4l2loopback.ko (vermagic $VM)"

if [[ -n $CAPTURE ]]; then
    mkdir -p "$CAPTURE"
    cp -a "$WORK/v4l2loopback.ko" "$CAPTURE/"
    ( cd "$CAPTURE" && sha256sum v4l2loopback.ko > sha256sums )
    say "captured into $CAPTURE (install-c20e-board-support.sh installs it from there)"
fi
