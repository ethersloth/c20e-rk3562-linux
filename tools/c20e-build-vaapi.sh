#!/usr/bin/env bash
# Build and install the hardware video decode stack ON THE TABLET (aarch64):
# Rockchip MPP plus the VA-API driver that sits on top of it, so Chrome (and
# anything else that speaks VA-API) decodes H.264/HEVC/VP8/VP9/AV1 on the
# RK3562's rkvdec2 instead of on the CPU.
#
#     sudo ./c20e-build-vaapi.sh                 build, patch, install
#     sudo ./c20e-build-vaapi.sh --capture DIR   also copy the artifacts to DIR
#                                                (that is how prebuilt/vaapi/
#                                                in this repo was produced)
#
# Both projects are pinned to the commits this port was tested against. The
# driver gets the two patches in overlay/vaapi-patches/ -- without the first,
# Chrome rejects every profile and silently decodes in software; without the
# second, 1080p playback runs at 15-20 fps in slow motion (see the patch
# headers for the measurements).
#
# install-c20e-board-support.sh installs the SAME artifacts from prebuilt/vaapi/
# into a Fedora image on the laptop, so a fresh install already has hardware
# decode; this script is for rebuilding them, or for a tablet installed before
# the prebuilt files existed.
set -Eeuo pipefail

MPP_URL="https://github.com/rockchip-linux/mpp.git"
MPP_REV="14729dd578e570e5f00fd1dd2113f5429012d64b"
VA_URL="https://github.com/woodyst/rockchip-vaapi.git"
VA_REV="e8c64ddc528c9b00b8f5c4041d0f28acfab5559d"
SRC="/usr/local/src"
DRI_DIR="/usr/lib64/dri"
CAPTURE=""

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PATCHES="$REPO/overlay/vaapi-patches"
OVERLAY="$REPO/overlay"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[vaapi] $*"; }

[[ ${1:-} == --capture ]] && { CAPTURE="${2:?--capture needs a directory}"; shift 2; }
[[ $EUID -eq 0 ]] || die "run as root (it installs into /usr/local and $DRI_DIR)"
[[ "$(uname -m)" == aarch64 ]] || die "run this ON THE TABLET; it builds native aarch64 binaries"
[[ -d $PATCHES ]] || die "missing $PATCHES (run this from a checkout of the repo)"

# libva-devel for the driver ABI headers, cmake/gcc/git for both trees.
missing=()
for p in gcc gcc-c++ cmake git make libva-devel; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then
    say "installing build dependencies: ${missing[*]}"
    dnf -y install "${missing[@]}"
fi

clone_at(){   # clone_at <url> <rev> <dir>
    local url=$1 rev=$2 dir=$3
    if [[ -d $dir/.git ]]; then
        git -C "$dir" fetch -q --depth 50 origin || true
    else
        rm -rf "$dir"; git clone -q "$url" "$dir"
    fi
    git -C "$dir" checkout -q "$rev" 2>/dev/null || die "commit $rev not found in $url"
    git -C "$dir" reset -q --hard "$rev"
    say "$(basename "$dir") at $(git -C "$dir" rev-parse --short HEAD)"
}

# ---- Rockchip MPP ----------------------------------------------------------
# MPP talks to /dev/mpp_service (the kernel's rkvdec2/vepu driver). Built as a
# shared library into /usr/local, which is why the ld.so.conf.d file below is
# needed: glibc does not search /usr/local/lib64 by default.
mkdir -p "$SRC"
clone_at "$MPP_URL" "$MPP_REV" "$SRC/mpp"
B="$SRC/mpp/build/linux/aarch64"
mkdir -p "$B"
( cd "$B" && cmake ../../.. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
install -D -m0644 "$OVERLAY/c20e-local-lib64.conf" /etc/ld.so.conf.d/c20e-local-lib64.conf
ldconfig
ldconfig -p | grep -F librockchip_mpp >/dev/null || die "librockchip_mpp is not in the library cache"
say "MPP installed: $(ls /usr/local/lib64/librockchip_mpp.so.*)"

# ---- the VA-API driver -----------------------------------------------------
clone_at "$VA_URL" "$VA_REV" "$SRC/rockchip-vaapi"
for p in "$PATCHES"/*.patch; do
    say "applying $(basename "$p")"
    git -C "$SRC/rockchip-vaapi" apply "$p" || die "$(basename "$p") did not apply"
done
make -C "$SRC/rockchip-vaapi" clean >/dev/null
make -C "$SRC/rockchip-vaapi" -j"$(nproc)" >/dev/null
install -D -m0755 "$SRC/rockchip-vaapi/rockchip_drv_video.so" "$DRI_DIR/rockchip_drv_video.so"
say "driver installed: $DRI_DIR/rockchip_drv_video.so"

# ---- runtime configuration -------------------------------------------------
# LIBVA_DRIVER_NAME, decoder device permissions, and Chrome's switches; all
# three are needed or the driver is built but never used.
install -D -m0644 "$OVERLAY/c20e-vaapi.conf"    /etc/environment.d/90-c20e-vaapi.conf
install -D -m0644 "$OVERLAY/70-c20e-mpp.rules"  /etc/udev/rules.d/70-c20e-mpp.rules
install -D -m0755 "$OVERLAY/vaapi/google-chrome-c20e" /usr/local/bin/google-chrome-stable
ln -sf google-chrome-stable /usr/local/bin/google-chrome
install -D -m0644 "$OVERLAY/vaapi/google-chrome.desktop" \
    /usr/local/share/applications/google-chrome.desktop
update-desktop-database /usr/local/share/applications 2>/dev/null || true
udevadm control --reload 2>/dev/null || true
udevadm trigger --subsystem-match=mpp_class --subsystem-match=dma_heap 2>/dev/null || true
restorecon -R /usr/local/bin /usr/local/lib64 "$DRI_DIR" /etc/environment.d 2>/dev/null || true

if [[ -n $CAPTURE ]]; then
    mkdir -p "$CAPTURE"
    # librockchip_mpp.so.1 (the soname) and .so are symlinks to the real file,
    # which MPP names .so.0 -- copy the file itself; the installer recreates the
    # links, since a dangling symlink in the repo is no use to anyone.
    MPP_LIB="$(readlink -f /usr/local/lib64/librockchip_mpp.so.1)"
    cp -aL "$MPP_LIB" "$CAPTURE/$(basename "$MPP_LIB")"
    cp -aL "$SRC/rockchip-vaapi/rockchip_drv_video.so" "$CAPTURE/"
    ( cd "$CAPTURE" && sha256sum "$(basename "$MPP_LIB")" rockchip_drv_video.so > sha256sums )
    cat > "$CAPTURE/provenance" <<EOF
# Built by tools/c20e-build-vaapi.sh on $(date -u +%Y-%m-%dT%H:%MZ), aarch64, on the tablet itself.
mpp             $MPP_URL @ $MPP_REV
rockchip-vaapi  $VA_URL @ $VA_REV
patches         $(cd "$PATCHES" && echo *.patch)
soname          librockchip_mpp.so.1 -> $(basename "$MPP_LIB")
kernel          $(uname -r)
gcc             $(gcc -dumpversion)
libva           $(rpm -q --qf '%{VERSION}' libva 2>/dev/null)
EOF
    say "captured artifacts + sha256sums + provenance in $CAPTURE"
fi

echo
say "done. Log out and back in (or reboot) so the session picks up"
say "LIBVA_DRIVER_NAME, then check with:  vainfo | head"
say "Chrome: the app-grid entry and 'google-chrome-stable' in a terminal both"
say "use the wrapper; 'lsof /dev/mpp_service' during playback proves it works."
