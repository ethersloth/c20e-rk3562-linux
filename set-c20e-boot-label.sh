#!/usr/bin/env bash
# Install the repo's extlinux.conf onto a card and pick the default label.
#
# Lets a boot option be changed without a rebuild or a full reflash, which
# matters for diagnosis runs: the kernel already has CONFIG_SLUB_DEBUG=y
# compiled in but dormant, so use-after-free detection is one boot parameter
# away.
#
# Usage: sudo ./set-c20e-boot-label.sh [/dev/sdX] [label]
#   labels: linux | linux-debug | linux-slub | linux-fallback | linux-fallback-debug
set -Eeuo pipefail

DEV="${1:-/dev/sda}"
LABEL="${2:-linux-slub}"
REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
SRC="$REPO/extlinux.conf"
MNT="$(mktemp -d)"

die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}3" ]] || die "no ${DEV}3 -- is the card in and is $DEV right?"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."
[[ -f "$SRC" ]] || die "missing $SRC"
grep -q "^label ${LABEL}$" "$SRC" || die "no 'label ${LABEL}' in $SRC"

echo "[*] mounting boot partition ${DEV}3"
mount "${DEV}3" "$MNT" || die "could not mount ${DEV}3"
[[ -d "$MNT/extlinux" ]] || die "${DEV}3 has no extlinux/ -- wrong partition?"

cp -a "$MNT/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf.bak" 2>/dev/null || true

# Ship the repo copy, then point the default at the requested label, so the
# card's boot config always matches what is committed.
sed "s/^default .*/default ${LABEL}/" "$SRC" > "$MNT/extlinux/extlinux.conf"
sync

echo "[+] installed extlinux.conf, default = ${LABEL}"
echo
echo "[*] active entry:"
sed -n "/^label ${LABEL}$/,/^$/p" "$MNT/extlinux/extlinux.conf" | sed 's/^/    /'

umount "$MNT"
echo
echo "SUCCESS - put the card in the tablet and power on."
[[ "$LABEL" == "linux-slub" ]] && cat <<'NOTE'

This is a DIAGNOSIS boot: slower, and it will log heavily.
Let it reach the desktop and sit for a minute or two, or until it reboots,
then bring the card back and run ./collect-c20e-logs.sh -- a SLUB report
names the allocation and free sites, which is what we are after.
NOTE
exit 0
