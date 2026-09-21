#!/bin/bash
# Repair a Fedora root that was prepared BEFORE install-c20e-board-support.sh
# learned about Fedora's first-boot preset and the Wi-Fi firmware. Run ON THE
# TABLET as root. make-c20e-fedora-bootpart.sh ships this script plus the
# firmware and preset on the eMMC boot partition, under /c20e:
#
#     mount LABEL=C20EBOOT /mnt && bash /mnt/c20e/c20e-fedora-live-fixup.sh
#
# 1. Wi-Fi firmware (SWT6621_*.bin etc.) -- without it skw_sdio logs
#    "request image fail" and wlan0 never appears
# 2. the c20e systemd preset, and re-enables the units first-boot preset-all
#    disabled (DDR pin, USB console, BT bring-up, camera, ttyGS0 getty)
# 3. tells you to reboot (unloading the Seekwave modules oopses the kernel)
set -euo pipefail
D="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

for fw in "$D"/firmware/*.bin; do
    install -m0644 "$fw" "/usr/lib/firmware/$(basename "$fw")"
done
echo "[fixup] installed Wi-Fi firmware: $(cd "$D/firmware" && echo *.bin)"

install -d /etc/systemd/system-preset
install -m0644 "$D/c20e.preset" /etc/systemd/system-preset/10-c20e.preset
restorecon -R /usr/lib/firmware /etc/systemd/system-preset 2>/dev/null || true
systemctl enable c20e-dvfs-policy.service c20e-usb-debug.service \
    c20e-bt-bringup.service c20e-camera.service serial-getty@ttyGS0.service
echo "[fixup] preset installed; c20e units + ttyGS0 getty enabled"

# Do NOT try to reload the Seekwave modules here: `modprobe -r skw
# skw_sdio_lite` oopses the kernel (segfault + "Internal error: Oops", seen
# 2026-09-21), and skw_sdio_lite then refuses to re-insert (EBUSY). The
# firmware is only read at probe time, so a reboot is the way to pick it up.
echo "[fixup] done. REBOOT now -- Wi-Fi loads its firmware at boot."
echo "        (never modprobe -r skw/skw_sdio_lite: unloading them oopses the kernel)"
