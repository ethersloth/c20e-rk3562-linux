#!/usr/bin/env bash
# Install the Bluetooth bring-up service, the stable Wi-Fi MAC, and the
# rebuilt Seekwave modules onto a card, without a rebuild.
#
# Three separate fixes, all needed together for Bluetooth:
#
#  1. skw_sdio_lite rebuilt with -DCONFIG_BT_SEEKWAVE. Without it,
#     skw_sdio_main.c never calls skw_sdio_bind_btseekwave_driver(), so the
#     "btseekwave" platform DEVICE is never created and skwbt's platform
#     DRIVER never probes. hci_register_dev() is unreachable.
#  2. c20e-bt-bringup. Even with (1) the probe runs during skw_sdio init,
#     before the chip's BT service is started, so its HCI Read Local Version
#     times out and registration still fails. The service starts the chip
#     side, then reloads skwbt so probe re-runs with the chip awake.
#  3. A fixed Wi-Fi MAC. Unrelated to BT, but the SV6160 has no NV blob and
#     invents a random MAC every boot, so the tablet's IP changed constantly.
#
# Usage: sudo ./apply-c20e-bt-and-mac.sh [/dev/sdX]
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
STAGE="$REPO/out/c20e-seekwave"
MNT="$(mktemp -d)"

die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}4" ]] || die "no ${DEV}4 -- is the card in and is $DEV right?"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
for f in c20e-bt-bringup.sh c20e-bt-bringup.service c20e-skw-mac.conf; do
    [[ -f "$REPO/overlay/$f" ]] || die "missing overlay/$f"
done
for m in skw_sdio_lite.ko skw.ko skwbt.ko; do
    [[ -f "$STAGE/$m" ]] || die "missing $STAGE/$m (run ./rebuild-c20e-hybrid-seekwave.sh)"
done

# The whole point of (1) is this define; refuse to ship a module without it.
grep -q 'btseekwave' "$STAGE/skw_sdio_lite.ko" \
    || die "$STAGE/skw_sdio_lite.ko has no btseekwave binding -- rebuild with -DCONFIG_BT_SEEKWAVE"

mount "${DEV}4" "$MNT" || die "could not mount ${DEV}4"
[[ -d "$MNT/etc/systemd/system" ]] || die "${DEV}4 does not look like the rootfs"

KREL="$(ls "$MNT/lib/modules" | head -1)"
[[ -n "$KREL" ]] || die "no kernel modules directory on the card"
MODDIR="$MNT/lib/modules/$KREL/updates/c20e-seekwave"
[[ -d "$MODDIR" ]] || die "missing $MODDIR"

echo "[*] kernel on card: $KREL"
echo "[*] installing rebuilt Seekwave modules"
for m in skw_sdio_lite.ko skw.ko skwbt.ko; do
    cp -a "$MODDIR/$m" "$MODDIR/$m.before-bt" 2>/dev/null || true
    install -m 0644 "$STAGE/$m" "$MODDIR/$m"
    echo "    $m"
done

# skwbt must NOT auto-load, or its probe runs before the chip BT service is
# started; that probe fails AND leaves the port claimed, after which the
# bring-up service's write to /proc/skwsdio/bt_service blocks and hangs the
# boot. Strip it from the load list; the bring-up service loads it later.
LOADCONF="$MNT/etc/modules-load.d/c20e-seekwave.conf"
if [[ -f "$LOADCONF" ]] && grep -qx 'skwbt' "$LOADCONF"; then
    cp -a "$LOADCONF" "$LOADCONF.before-bt"
    sed -i '/^skwbt$/d' "$LOADCONF"
    echo "[+] removed skwbt from modules-load.d (bring-up service loads it instead)"
fi

echo "[*] installing Bluetooth bring-up service"
install -m 0755 "$REPO/overlay/c20e-bt-bringup.sh" "$MNT/usr/local/sbin/c20e-bt-bringup"
install -m 0644 "$REPO/overlay/c20e-bt-bringup.service" \
    "$MNT/etc/systemd/system/c20e-bt-bringup.service"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/c20e-bt-bringup.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/c20e-bt-bringup.service"

echo "[*] installing stable Wi-Fi MAC"
install -m 0644 "$REPO/overlay/c20e-skw-mac.conf" "$MNT/etc/modprobe.d/c20e-skw-mac.conf"

# depmod must run against the card's kernel, not the host's.
if command -v depmod >/dev/null; then
    depmod -b "$MNT" "$KREL" 2>/dev/null && echo "[+] depmod done" || echo "[!] depmod failed (modules are in updates/, usually still fine)"
fi

sync
echo
echo "[*] verification:"
echo "    btseekwave in installed module: $(strings "$MODDIR/skw_sdio_lite.ko" | grep -c btseekwave)"
echo "    bringup service:                $([[ -e "$MNT/etc/systemd/system/multi-user.target.wants/c20e-bt-bringup.service" ]] && echo enabled || echo MISSING)"
echo "    mac option:                     $(grep -o 'mac=.*' "$MNT/etc/modprobe.d/c20e-skw-mac.conf")"
echo "    skwbt auto-load:                $(grep -qx 'skwbt' "$LOADCONF" 2>/dev/null && echo 'STILL PRESENT (bad)' || echo 'removed (good)')"

umount "$MNT"
echo
echo "SUCCESS - put the card in the tablet and boot."
echo "Expect a STABLE IP now (the MAC no longer changes), and hci0 to exist."
echo "Check on the tablet with:  ls /sys/class/bluetooth/ ; bluetoothctl list"
echo "If hci0 is missing, /var/log/c20e-bt-bringup.log says how far it got."
