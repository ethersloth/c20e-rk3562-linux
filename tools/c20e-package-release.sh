#!/usr/bin/env bash
# Package the built images for a GitHub release.
#
#     ./c20e-package-release.sh [tag]            # default tag: fedora44-<date>
#     ./c20e-package-release.sh tag --with-emmc-bundle
#
# GitHub caps a release asset at 2 GiB, and the SD image is about 4.7 GB, so the
# assets are split into parts of 1900 MiB. Reassembly is a plain `cat`, and the
# checksums here cover BOTH the parts and the whole file, so anyone can verify
# what they downloaded and what they reassembled.
#
# The eMMC bundle is only needed by someone installing from an already-running
# system; the SD image carries its own copy under
# /usr/local/share/c20e-installer, so it is left out unless asked for.
#
# Output: out/release/<tag>/ with the parts, SHA256SUMS, RELEASE-NOTES.md, and
# the exact gh command to create a DRAFT release. Nothing is uploaded from here.
set -Eeuo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TAG="${1:-fedora44-$(date +%Y%m%d)}"
[[ ${1:-} == --* ]] && TAG="fedora44-$(date +%Y%m%d)"
WITH_BUNDLE=0
for a in "$@"; do [[ $a == --with-emmc-bundle ]] && WITH_BUNDLE=1; done

SD="$REPO/out/fedora-sd/c20e-fedora-sd.img.xz"
BUNDLE="$REPO/out/fedora-emmc"
OUT="$REPO/out/release/$TAG"
PART_SIZE="1900M"          # < 2 GiB, GitHub's per-asset limit

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "[release] $*"; }

[[ -f "$SD" ]] || die "no SD image at $SD (run make-c20e-fedora-sd.sh)"
[[ -f "$BUNDLE/manifest" ]] || die "no bundle manifest at $BUNDLE"
command -v split >/dev/null || die "missing split"
# shellcheck disable=SC1091
. "$BUNDLE/manifest"

rm -rf "$OUT"; mkdir -p "$OUT"

say "verifying the SD image against the checksum written at build time..."
if [[ -f "$SD.sha256" ]]; then
    ( cd "$(dirname "$SD")" && sha256sum -c "$(basename "$SD").sha256" >/dev/null ) \
        || die "the SD image does not match its .sha256 -- rebuild it"
else
    say "WARNING: no $SD.sha256 to check against"
fi
SD_SUM="$(sha256sum "$SD" | cut -d' ' -f1)"
SD_SIZE="$(du -h "$SD" | cut -f1)"

split_asset(){   # split_asset <file> <basename>
    local src=$1 base=$2
    say "splitting $(basename "$src") ($(du -h "$src" | cut -f1)) into $PART_SIZE parts..."
    split -b "$PART_SIZE" -d --suffix-length=2 "$src" "$OUT/$base.part"
    ls -1 "$OUT/$base.part"* | while read -r p; do
        printf '    %s  %s\n' "$(du -h "$p" | cut -f1)" "$(basename "$p")"
    done
}

split_asset "$SD" "c20e-fedora-sd.img.xz"

say "checking that the parts reassemble to the original..."
CAT_SUM="$(cat "$OUT"/c20e-fedora-sd.img.xz.part* | sha256sum | cut -d' ' -f1)"
[[ "$CAT_SUM" == "$SD_SUM" ]] || die "reassembled parts do not match the source image"
say "reassembly verified"

if (( WITH_BUNDLE )); then
    say "packing the eMMC bundle (for installing from a running system)..."
    tar -C "$REPO/out" -cf "$OUT/c20e-fedora-emmc-bundle.tar" fedora-emmc
    split_asset "$OUT/c20e-fedora-emmc-bundle.tar" "c20e-fedora-emmc-bundle.tar"
    BUNDLE_SUM="$(sha256sum "$OUT/c20e-fedora-emmc-bundle.tar" | cut -d' ' -f1)"
    rm -f "$OUT/c20e-fedora-emmc-bundle.tar"
fi

# no ./ prefix: users run `sha256sum -c SHA256SUMS` in their download directory
( cd "$OUT" && sha256sum c20e-*.part* > SHA256SUMS )
{
    echo "# whole files, after reassembly with cat"
    echo "$SD_SUM  c20e-fedora-sd.img.xz"
    [[ -n "${BUNDLE_SUM:-}" ]] && echo "$BUNDLE_SUM  c20e-fedora-emmc-bundle.tar"
} > "$OUT/SHA256SUMS.whole"

cat > "$OUT/RELEASE-NOTES.md" <<EOF
# Fedora 44 KDE Plasma Mobile for the C20e (RK3562) — $TAG

An installer SD card image for the "C20e" RK3562 tablet. Boot it from a card, try
it, and optionally install to the internal eMMC from the app grid.

Built from [\`$(git -C "$REPO" rev-parse --short HEAD)\`](https://github.com/ethersloth/c20e-rk3562-linux/commit/$(git -C "$REPO" rev-parse HEAD)) — kernel **$KERNEL** (Panfrost), Fedora KDE Mobile 44 base.

## Download and write

The image is split because a GitHub release asset cannot exceed 2 GiB.

\`\`\`bash
# 1. download every c20e-fedora-sd.img.xz.part* file, plus SHA256SUMS
sha256sum -c SHA256SUMS            # checks the downloaded parts

# 2. reassemble and check the whole file
cat c20e-fedora-sd.img.xz.part* > c20e-fedora-sd.img.xz
sha256sum -c SHA256SUMS.whole

# 3. write it to a card of 16 GB or more -- check the device name first!
lsblk
xz -dc c20e-fedora-sd.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
\`\`\`

You can also write the reassembled \`.img.xz\` with balenaEtcher or GNOME Disks.
Do **not** use \`dd conv=sparse\`: it leaves the card's old contents in the gaps,
and on a reused Rockchip card that can include a stale bootloader the BootROM
will find first.

## Installing to the internal eMMC

Boot the card, then run **"Install Fedora to internal storage"** from the app
grid. It erases Android, asks you to type \`ERASE-ANDROID\`, and refuses unless it
is running from the card and the target is the internal eMMC.

> An SD card boots only while the eMMC has no bootable bootloader, i.e. while the
> tablet still has Android on it. Once Fedora is on the eMMC, the tablet boots the
> eMMC even with a card inserted. Loader mode (hold **Volume Up** while powering
> on with a USB cable attached) is the way back in either case.

**Back up Android first** if you may want it back — \`backup-c20e-emmc.sh\` in the
repository makes a sector-exact image.

## What works

Boot, desktop, touch and auto-rotation; GPU (Panfrost, OpenGL ES 3.1); Wi-Fi;
Bluetooth; audio (speaker); rear camera as a normal 1280x720 webcam; suspend and
resume; USB-C with automatic host/device switching, a serial console and USB
Ethernet; firewall; battery, charging and backlight; hardware video decode in
Chrome; and shutdown.

## What does not

* **The NPU does not work** — its driver cannot request its own register region.
* **Plasma Camera cannot work** — it enumerates cameras only through libcamera,
  which has no pipeline handler for this vendor ISP. Install \`cheese\` (or
  \`snapshot\`) and use the **Camera** entry; the image ships no working camera app.
* 1080p60 video plays at about 50 fps; 1080p30 is smooth.
* SELinux is permissive.
* The front camera is raw Bayer only, so only the rear one appears as a webcam.
* Untested: headphone and headset-mic switching, Bluetooth audio, video encode,
  Firefox VA-API.

## Please read: the USB serial console is a root shell

Plug the tablet into a computer and \`/dev/ttyACM0\` is a **root shell with no
password** — the screen lock does not apply. It is deliberate: it is the only way
back in when the display stack fails, and this tablet has no UART without opening
the case. It needs physical USB access. To switch it off once you are set up:

\`\`\`bash
sudo rm -r /etc/systemd/system/serial-getty@ttyGS0.service.d
sudo systemctl daemon-reload
\`\`\`

## First boot notes

* The filesystem grows to fill the card or eMMC on first boot.
* \`sudo dnf install cheese\` for the camera.
* Chrome gets hardware video decode through a wrapper that is already installed;
  launch it normally.

Everything here is reproducible from the repository — see the README.
EOF

echo
say "done: $OUT"
ls -1sh "$OUT"
echo
say "create a DRAFT release with:"
echo
echo "  gh release create $TAG --draft --title \"Fedora 44 KDE Plasma Mobile for C20e ($TAG)\" \\"
echo "    --notes-file $OUT/RELEASE-NOTES.md \\"
echo "    $(cd "$OUT" && ls -1 c20e-*.part* SHA256SUMS SHA256SUMS.whole | sed "s|^|$OUT/|" | tr '\n' ' ')"
echo
say "review the draft on GitHub, then publish it there (or: gh release edit $TAG --draft=false)"
