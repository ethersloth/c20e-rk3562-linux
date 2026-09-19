#!/usr/bin/env bash
# Pull every post-mortem artifact off a C20e card into out/c20e-logs/.
#
# For when the tablet boots far enough to run but not far enough to reach the
# USB serial gadget -- a panic loop, a hang, or a driver that never settles.
# Everything is mounted READ-ONLY, so a card captured this way can go straight
# back in the tablet.
#
# Sources, in the order they are usually useful:
#   pstore/ramoops   the tail of the console from the PREVIOUS boot, which is
#                    the only thing that survives a panic-triggered reboot
#   journal          persistent journal, if journald was writing one
#   /var/log         plain-text logs for the pre-journal part of boot
#   boot partition   extlinux.conf and the kernel/dtb actually being booted
#
# Usage: sudo ./collect-c20e-logs.sh [/dev/sdX]
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
OUT="$REPO/out/c20e-logs"
MNT="$(mktemp -d)"

die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}4" ]] || die "no ${DEV}4 -- is the card in and is $DEV right?"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "[*] rootfs (${DEV}4), read-only"
mount -o ro "${DEV}4" "$MNT" || die "could not mount ${DEV}4"

# The previous boot's console tail. Systemd copies ramoops here on startup, so
# this survives the reboot that a panic causes -- unlike the journal.
for d in "$MNT/var/lib/systemd/pstore" "$MNT/sys/fs/pstore"; do
    if [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
        echo "[+] pstore: $d"
        cp -a "$d" "$OUT/pstore-$(basename "$(dirname "$d")")" 2>/dev/null || true
    fi
done

if [[ -d "$MNT/var/log/journal" ]] && [[ -n "$(ls -A "$MNT/var/log/journal" 2>/dev/null)" ]]; then
    echo "[+] persistent journal"
    cp -a "$MNT/var/log/journal" "$OUT/journal"
    # -D reads an offline journal directory; --no-pager keeps it scriptable.
    journalctl -D "$OUT/journal" --no-pager -b -1 > "$OUT/journal-prev-boot.txt" 2>/dev/null || true
    journalctl -D "$OUT/journal" --no-pager -b  0 > "$OUT/journal-last-boot.txt" 2>/dev/null || true
    journalctl -D "$OUT/journal" --no-pager -p warning \
        > "$OUT/journal-warnings.txt" 2>/dev/null || true
else
    echo "[-] no persistent journal (journald was writing to /run, which is RAM)"
fi

echo "[*] /var/log"
mkdir -p "$OUT/var-log"
find "$MNT/var/log" -maxdepth 1 -type f -size -20M \
    -exec cp -a {} "$OUT/var-log/" \; 2>/dev/null || true

# First-boot wizard state: tells us whether the card ever reached the point of
# running it, which separates "kernel never finished" from "userspace stalled".
echo "[*] first-boot state"
{
    echo "== /var/lib/c20e =="; ls -la "$MNT/var/lib/c20e" 2>/dev/null || echo "(absent)"
    echo; echo "== default.target =="
    readlink -f "$MNT/etc/systemd/system/default.target" 2>/dev/null || echo "(unset)"
    echo; echo "== masked units =="
    find "$MNT/etc/systemd/system" -maxdepth 1 -lname /dev/null -printf '%f\n' 2>/dev/null
    echo; echo "== c20e units =="
    ls -la "$MNT/etc/systemd/system/"*c20e* 2>/dev/null || echo "(none)"
} > "$OUT/firstboot-state.txt" 2>&1

echo "[*] kernel modules present"
ls "$MNT/lib/modules" > "$OUT/kernel-versions.txt" 2>&1 || true

umount "$MNT"

echo "[*] boot partition (${DEV}3), read-only"
if mount -o ro "${DEV}3" "$MNT" 2>/dev/null; then
    cp -a "$MNT/extlinux/extlinux.conf" "$OUT/extlinux.conf" 2>/dev/null || true
    ls -la "$MNT" > "$OUT/boot-listing.txt" 2>&1
    sha256sum "$MNT"/* 2>/dev/null >> "$OUT/boot-listing.txt" || true
    umount "$MNT"
fi

chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$OUT" 2>/dev/null || true

echo
echo "[+] Collected into $OUT:"
find "$OUT" -maxdepth 1 -printf '  %f\n' | sort
