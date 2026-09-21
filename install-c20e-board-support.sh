#!/usr/bin/env bash
# Install everything the C20e hardware needs into a rootfs, distro-agnostically.
#
# The hardware enablement for this tablet is small and has no Debian in it: a
# handful of services, two module config files, one firmware blob, the
# out-of-tree Seekwave modules, and one small binary. build_rootfs.sh is 5500
# lines mostly because of Debian desktop setup -- almost none of that is board
# support.
#
# Splitting it out means a Fedora (or any systemd distro) rootfs only needs:
#   1. a base system installed however that distro does it
#   2. this script
#
# Requirements of the target rootfs:
#   - systemd
#   - v4l-utils        (media-ctl, v4l2-ctl)   for the camera pipeline
#   - kmod             (modprobe, depmod)
#   - NetworkManager   for the Wi-Fi MAC policy (skipped if absent)
#
# Usage:
#   sudo ./install-c20e-board-support.sh /path/to/rootfs
#   sudo ./install-c20e-board-support.sh /            # on the running device
set -Eeuo pipefail

ROOT="${1:-}"
REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
STAGE="$REPO/out/c20e-seekwave"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[c20e-bsp] $*"; }

[[ -n "$ROOT" ]] || die "usage: $0 /path/to/rootfs"
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -d "$ROOT/etc" && -d "$ROOT/usr" ]] || die "$ROOT does not look like a rootfs"
[[ -d "$ROOT/lib/modules" ]] || die "$ROOT has no /lib/modules -- install the kernel first"

KREL="$(ls "$ROOT/lib/modules" | head -1)"
[[ -n "$KREL" ]] || die "no kernel version under $ROOT/lib/modules"
say "target rootfs : $ROOT"
say "kernel        : $KREL"

install -d "$ROOT/etc/systemd/system/multi-user.target.wants" \
           "$ROOT/etc/modprobe.d" "$ROOT/etc/modules-load.d" \
           "$ROOT/usr/local/sbin" "$ROOT/usr/local/bin" \
           "$ROOT/lib/firmware/seekwave" \
           "$ROOT/lib/modules/$KREL/updates/c20e-seekwave"

enable_unit(){   # $1 = unit file name
    ln -sf "/etc/systemd/system/$1" "$ROOT/etc/systemd/system/multi-user.target.wants/$1"
}

# ---------------------------------------------------------------- Wi-Fi / BT
# Seekwave modules are matched to the kernel by vermagic, so they must come
# from a build against THIS kernel.
if [[ -d "$STAGE" ]]; then
    for m in skw_sdio_lite.ko skw.ko skwbt.ko; do
        [[ -f "$STAGE/$m" ]] || die "missing $STAGE/$m (run ./rebuild-c20e-hybrid-seekwave.sh)"
    done
    grep -q btseekwave "$STAGE/skw_sdio_lite.ko" \
        || die "skw_sdio_lite.ko lacks the btseekwave binding; rebuild with -DCONFIG_BT_SEEKWAVE"
    vm="$(modinfo -F vermagic "$STAGE/skw_sdio_lite.ko" 2>/dev/null | awk '{print $1}')"
    [[ "$vm" == "$KREL" ]] || die "Seekwave modules are for kernel '$vm', rootfs has '$KREL'"
    install -m0644 "$STAGE"/skw_sdio_lite.ko "$STAGE"/skw.ko "$STAGE"/skwbt.ko \
        "$ROOT/lib/modules/$KREL/updates/c20e-seekwave/"
    say "installed Seekwave modules (vermagic $vm)"
else
    die "missing $STAGE -- run ./rebuild-c20e-hybrid-seekwave.sh first"
fi

# skwbt must NOT auto-load: probing before the chip's BT service is started
# leaves the port claimed, and the later write to /proc/skwsdio/bt_service then
# blocks, which hangs the boot. c20e-bt-bringup loads it at the right moment.
printf 'skw_sdio_lite\nskw\n' > "$ROOT/etc/modules-load.d/c20e-seekwave.conf"
printf 'options skwbt firmware_dir=seekwave\n' > "$ROOT/etc/modprobe.d/c20e-skwbt.conf"
install -m0644 "$REPO/overlay/c20e-skw-mac.conf" "$ROOT/etc/modprobe.d/c20e-skw-mac.conf"
install -m0644 "$REPO/overlay/firmware/seekwave/sv6160.nvbin" "$ROOT/lib/firmware/seekwave/sv6160.nvbin"
# Wi-Fi firmware. skw_sdio's boot loader requests SWT6621_DRAM_SDIO.bin (and
# the IRAM image); without them it logs "request image fail" and there is no
# wlan0 at all. The Debian build copies all of overlay/firmware/; this
# installer originally copied only the BT nvbin, so the first Fedora image had
# no Wi-Fi (2026-09-21).
for fw in "$REPO"/overlay/firmware/*.bin; do
    install -m0644 "$fw" "$ROOT/lib/firmware/$(basename "$fw")"
done
say "installed BT NV firmware + module policy"

if [[ -d "$ROOT/etc/NetworkManager" ]] || [[ -e "$ROOT/usr/sbin/NetworkManager" ]]; then
    install -d "$ROOT/etc/NetworkManager/conf.d"
    install -m0644 "$REPO/overlay/c20e-nm-no-mac-randomization.conf" \
        "$ROOT/etc/NetworkManager/conf.d/99-c20e-no-mac-randomization.conf"
    say "installed NetworkManager MAC policy"
else
    say "NetworkManager not present; skipping MAC randomization policy"
fi

# ------------------------------------------------------------------ services
for pair in "c20e-bt-bringup:sbin" "c20e-dvfs-policy:sbin" "c20e-camera:sbin" "c20e-usb-debug:sbin" "c20e-audio-init:sbin" "c20e-accel-enable:sbin"; do
    name="${pair%%:*}"
    install -m0755 "$REPO/overlay/$name.sh"      "$ROOT/usr/local/sbin/$name"
    install -m0644 "$REPO/overlay/$name.service" "$ROOT/etc/systemd/system/$name.service"
    enable_unit "$name.service"
    say "installed + enabled $name.service"
done

# USB serial console on the gadget port (/dev/ttyGS0 on the tablet, which
# appears as /dev/ttyACM0 on a host). This is the recovery path that depends on
# neither the GPU nor Wi-Fi: if the desktop or the network fails to come up,
# this still gives a login prompt over the USB-C cable.
install -d "$ROOT/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
    "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
say "enabled login getty on ttyGS0 (USB serial console)"

# Accelerometer -> iio-sensor-proxy (auto-rotation). See overlay/61-c20e-accel.rules.
install -d "$ROOT/etc/udev/rules.d"
install -m0644 "$REPO/overlay/61-c20e-accel.rules" "$ROOT/etc/udev/rules.d/61-c20e-accel.rules"
say "installed accelerometer udev rule (auto-rotation)"

# Presets, so the enable links SURVIVE a first boot. Fedora's systemd does a
# FULL `preset-all` on first boot (machine-id "uninitialized"), which DISABLES
# every unit its preset lists do not mention: on 2026-09-21 that silently
# removed all four c20e units and the ttyGS0 getty, so the first Fedora boot on
# the eMMC had no DDR pin (GUI hang) and no USB console. Harmless on Debian.
install -d "$ROOT/etc/systemd/system-preset"
install -m0644 "$REPO/overlay/c20e.preset" "$ROOT/etc/systemd/system-preset/10-c20e.preset"
say "installed systemd preset (keeps c20e units enabled across first-boot preset-all)"

# --------------------------------------------------------------- ISP gain
# Without this the ISP output is nearly black; there is no 3A on this board.
if [[ -f "$REPO/tools/rkisp32_gain.c" ]]; then
    if aarch64-linux-gnu-gcc -O2 -I"$REPO/src/kernel/include/uapi" \
         -o "$ROOT/usr/local/bin/c20e-isp-gain" "$REPO/tools/rkisp32_gain.c" 2>/dev/null; then
        say "compiled c20e-isp-gain"
    else
        # Ship the source AND the Rockchip vendor ISP uapi headers it needs:
        # distro kernel-headers are mainline and lack rk-isp32-config.h and its
        # chain, so a plain on-device gcc fails without them.
        install -d "$ROOT/usr/local/src" "$ROOT/usr/local/include/linux"
        install -m0644 "$REPO/tools/rkisp32_gain.c" "$ROOT/usr/local/src/rkisp32_gain.c"
        for h in rk-isp32-config.h rk-isp3-config.h rk-isp21-config.h rk-isp2-config.h \
                 rk-camera-module.h rk-video-format.h; do
            install -m0644 "$REPO/src/kernel/include/uapi/linux/$h" "$ROOT/usr/local/include/linux/$h"
        done
        say "WARNING: could not cross-compile c20e-isp-gain (bare cross-compiler?)."
        say "         source + vendor headers shipped -- build on the device (needs gcc, v4l-utils):"
        say "         gcc -O2 -I/usr/local/include -o /usr/local/bin/c20e-isp-gain /usr/local/src/rkisp32_gain.c"
    fi
fi

depmod -b "$ROOT" "$KREL" 2>/dev/null && say "depmod done" || say "depmod skipped"
sync

echo
say "verification:"
printf '    seekwave modules : %s\n' "$(ls "$ROOT/lib/modules/$KREL/updates/c20e-seekwave" 2>/dev/null | tr '\n' ' ')"
printf '    wifi firmware    : %s\n' "$([[ -f "$ROOT/lib/firmware/SWT6621_DRAM_SDIO.bin" && -f "$ROOT/lib/firmware/SWT6621_IRAM_SDIO.bin" ]] && echo yes || echo MISSING)"
printf '    bt nv firmware   : %s\n' "$([[ -f "$ROOT/lib/firmware/seekwave/sv6160.nvbin" ]] && echo yes || echo MISSING)"
printf '    isp gain binary  : %s\n' "$([[ -x "$ROOT/usr/local/bin/c20e-isp-gain" ]] && echo yes || echo 'not built (source shipped)')"
printf '    enabled units    : %s\n' "$(ls "$ROOT/etc/systemd/system/multi-user.target.wants" 2>/dev/null | grep -c c20e) c20e units"
printf '    skwbt auto-load  : %s\n' "$(grep -qx skwbt "$ROOT/etc/modules-load.d/c20e-seekwave.conf" && echo 'PRESENT (bad)' || echo 'absent (good)')"
echo
say "done. The rootfs still needs: systemd, v4l-utils (media-ctl, v4l2-ctl: the camera"
say "     service fails without them), kmod, alsa-utils, NetworkManager, and gcc to build the ISP gain tool."
