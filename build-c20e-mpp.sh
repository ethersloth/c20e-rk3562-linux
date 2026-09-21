#!/usr/bin/env bash
# Build Rockchip MPP (the hardware video codec library) for the C20e.
#
# Why this exists: the librockchip_mpp on the tablet dates from May 2021.
# Current MPP decodes H.264 on this RK3562 correctly and fast -- verified with
# mpi_dec_test against /dev/mpp_service, frame-accurate against a known
# testsrc2 pattern:
#
#   720p  H.264:   software 50 fps (all 4 A53 cores)  ->  MPP 256 fps
#   1080p H.264:   software 28 fps (cannot keep up)   ->  MPP 128.6 fps
#
# Why podman and not the Fedora cross compiler: Fedora's
# gcc-c++-aarch64-linux-gnu ships NO C++ standard library (no headers, no
# libstdc++.a) -- it is for kernel and bare-metal use. MPP is partly C++, so it
# cannot be built that way at all. Building inside a native Debian 13 arm64
# container (qemu-user binfmt) produces binaries whose glibc and libstdc++
# match the tablet exactly.
#
# NOTE: MPP's own "build/" directory holds required cmake modules
# (merge_objects.cmake, version.in). It is NOT a build output -- never delete
# it. This script builds in build-c20e/ instead.
#
# Output: out/c20e-mpp/{lib,bin}
#
# Usage: ./build-c20e-mpp.sh [mpp-git-ref]
set -Eeuo pipefail

REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
SRC="$REPO/c20e-thirdparty/mpp"
OUT="$REPO/out/c20e-mpp"
REF="${1:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v podman >/dev/null || die "podman is required"
[[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
    || die "no qemu-aarch64 binfmt handler; install qemu-user-static"

if [[ ! -d "$SRC/.git" ]]; then
    git clone https://github.com/rockchip-linux/mpp.git "$SRC"
fi
if [[ -n "$REF" ]]; then git -C "$SRC" fetch --depth 1 origin "$REF" && git -C "$SRC" checkout -q FETCH_HEAD; fi
[[ -f "$SRC/build/cmake/merge_objects.cmake" ]] \
    || die "$SRC/build/cmake is missing -- restore it with: git -C $SRC checkout -- build/"
echo "[*] MPP at $(git -C "$SRC" log -1 --format='%h %cd' --date=short)"

rm -rf "$OUT"; mkdir -p "$OUT"
podman run --rm --arch arm64 \
  -v "$SRC:/src/mpp:Z" -v "$OUT:/out:Z" \
  docker.io/library/debian:trixie bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq cmake g++ make pkg-config libdrm-dev >/dev/null
    cd /src/mpp && rm -rf build-c20e && mkdir build-c20e && cd build-c20e
    cmake .. -DCMAKE_BUILD_TYPE=Release -DRKPLATFORM=ON -DHAVE_DRM=ON -DBUILD_TEST=ON >/dev/null
    make -j"$(nproc)" >/dev/null
    mkdir -p /out/lib /out/bin
    cp -a mpp/librockchip_mpp.so* /out/lib/
    cp test/mpi_dec_test test/mpp_info_test /out/bin/
  '
echo "[+] built:"; ls -la "$OUT/lib" "$OUT/bin"
echo
echo "Test on the tablet WITHOUT replacing the system library:"
echo "  LD_LIBRARY_PATH=\$HOME/mpp/lib \$HOME/mpp/bin/mpi_dec_test -i clip.h264 -t 7"
