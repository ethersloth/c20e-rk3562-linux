#!/usr/bin/env bash
# Rebuild the C20e "V5.9r2 hybrid" Seekwave Wi-Fi modules against the kernel
# currently in src/kernel, and stage them for installation.
#
# Why this exists: the working Wi-Fi configuration on this board is NOT the
# in-tree driver under overlay/drivers/net/wireless/ea6621q/. It is a hybrid:
#
#   skw_sdio_lite.ko  - MODERN SDIO layer, from c20e-thirdparty/seekwave-swt6621s
#   skw.ko            - legacy skwifi upper, recompiled against the MODERN
#                       skw_platform_data.h and the legacy skw6160_config.h
#
# Module vermagic is tied to the kernel build, so these must be rebuilt every
# time the kernel is rebuilt. build.sh no longer builds the in-tree driver
# (see the Seekwave block there); without these modules there is no Wi-Fi.
#
# Recipes taken verbatim from prepare-c20e-v5.9r1-wifi-bind-protocol.sh (BSP)
# and prepare-c20e-v5.9r2-hybrid-seekwave.sh (upper).
set -Eeuo pipefail

REPO="${RKDEBIAN_REPO:-$(cd "$(dirname "$0")" && pwd)}"
KERNEL="$REPO/src/kernel"
MODERN="$REPO/c20e-thirdparty/seekwave-swt6621s"
OLD_SRC="$REPO/overlay/drivers/net/wireless/ea6621q/skwifi"
OLD_CFG="$REPO/overlay/include/linux/platform_data/skw6160_config.h"
LEGACY="$REPO/c20e-thirdparty/skwifi-sv6160-legacy"
STAGE="$REPO/out/c20e-seekwave"
CROSS=aarch64-linux-gnu-

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ -d "$KERNEL" ]]  || die "kernel tree missing: $KERNEL"
[[ -d "$MODERN" ]]  || die "modern Seekwave BSP missing: $MODERN"
[[ -d "$OLD_SRC" ]] || die "legacy skwifi source missing: $OLD_SRC"
[[ -f "$OLD_CFG" ]] || die "legacy skw6160_config.h missing: $OLD_CFG"
[[ -f "$KERNEL/.config" ]] || die "kernel is not configured; run ./build.sh extboot first"

# Refuse to run if the in-tree driver is enabled -- it would claim the SDIO
# device before these modules could, making them useless.
if grep -qx 'CONFIG_SEEKWAVE_BSP_DRIVERS=y' "$KERNEL/.config"; then
    die "in-tree Seekwave driver is built in (=y); rebuild the kernel with it disabled first"
fi

KREL="$(make -s -C "$KERNEL" ARCH=arm64 kernelrelease)"
echo "[*] kernel release: $KREL"

JOBS="${JOBS:-$(nproc)}"; [[ "$JOBS" -gt 8 ]] && JOBS=8
echo "[*] build jobs: $JOBS"

echo "[1/4] Refresh the legacy hybrid source tree"
rm -rf "$LEGACY"
cp -a "$OLD_SRC" "$LEGACY"
cp -a "$MODERN/include/linux/platform_data/skw_platform_data.h" "$LEGACY/skw_platform_data.h"
cp -a "$OLD_CFG" "$LEGACY/skw6160_config.h"

# c20e-thirdparty/ is gitignored, so fixes to the vendor BSP must live in the
# repo as patches and be re-applied here, or a fresh clone silently loses them.
PATCHDIR="$REPO/overlay/seekwave-patches"
if [[ -d "$PATCHDIR" ]]; then
    for p in "$PATCHDIR"/*.patch; do
        [[ -f "$p" ]] || continue
        if (cd "$MODERN" && patch -p1 --dry-run -R -s -f < "$p" >/dev/null 2>&1); then
            echo "[*] already applied: $(basename "$p")"
        elif (cd "$MODERN" && patch -p1 -s -f < "$p"); then
            echo "[+] applied: $(basename "$p")"
        else
            die "failed to apply $(basename "$p") to the Seekwave BSP"
        fi
    done
fi

echo "[2/4] Build the MODERN Seekwave BSP (provides skw_sdio_lite + Module.symvers)"
# -DCONFIG_BT_SEEKWAVE is required for Bluetooth to work at all.
#
# skw_sdio_main.c guards the call that creates the platform device:
#
#     #ifdef CONFIG_BT_SEEKWAVE
#         skw_sdio_bind_btseekwave_driver(skw_sdio->sdio_func[FUNC_1]);
#     #endif
#
# skwbt.ko registers a platform DRIVER named "btseekwave", but a platform
# driver with no matching device never probes, so hci_register_dev() is never
# reached and /sys/class/bluetooth stays empty. Without this define the chip
# side comes up perfectly -- `echo start > /proc/skwsdio/bt_service` reports
# "LOOPCHECK channel received: BTREADY" and "boot bt sucessfully" -- while the
# host never gains a controller, which looks like Bluetooth being broken
# rather than a missing build flag.
#
# CONFIG_SKW_BT stays =n here: that selects the skwbt module itself, which is
# built separately in step 4 from $MODERN/drivers/swtbt4l.
#
# The define goes in KCFLAGS, NOT skw_extra_flags. The BSP's own top-level
# Makefile does `skw_extra_flags := -I$(src)/include/linux ...`, and a
# command-line assignment would override that and drop the include paths,
# breaking the build.
make -C "$KERNEL" M="$MODERN" ARCH=arm64 CROSS_COMPILE="$CROSS" clean
make -j"$JOBS" -C "$KERNEL" M="$MODERN" ARCH=arm64 CROSS_COMPILE="$CROSS" \
    KCFLAGS="-Wno-error=int-in-bool-context -DCONFIG_BT_SEEKWAVE" \
    CONFIG_SEEKWAVE_BSP_DRIVERS=m CONFIG_SKW_NO_CONFIG=y CONFIG_SKW_SDIOHAL=m \
    CONFIG_WLAN_VENDOR_SWT6621S=m CONFIG_SKW_BT=n CONFIG_SWT6621S_LOG_DEBUG=y modules

BSP_KO="$MODERN/drivers/seekwaveplatform_lite/skw_sdio_lite.ko"
[[ -f "$BSP_KO" ]] || die "skw_sdio_lite.ko was not produced"

echo "[3/4] Build the legacy Wi-Fi upper against the modern BSP symbols"
make -C "$KERNEL" M="$LEGACY" ARCH=arm64 CROSS_COMPILE="$CROSS" clean
make -j"$JOBS" -C "$KERNEL" M="$LEGACY" ARCH=arm64 CROSS_COMPILE="$CROSS" \
    CONFIG_WLAN_VENDOR_SEEKWAVE=m \
    CONFIG_SKW_VENDOR=y \
    skw_extra_flags="-I$LEGACY -include $LEGACY/skw6160_config.h -DCONFIG_SEEKWAVE_PLD_RELEASE" \
    skw_extra_symbols="$MODERN/Module.symvers" \
    KCFLAGS='-Wno-error' modules

WIFI_KO="$LEGACY/skw.ko"
[[ -f "$WIFI_KO" ]] || die "skw.ko was not produced"

echo "[4/5] Build the Bluetooth upper module against the same BSP symbols"
# Recipe from the (retired) prepare-c20e-v5.9r3 script. Built against the
# Module.symvers just regenerated above, so it matches the skw_sdio_lite that
# will actually be loaded -- which the original v5.9r3 attempt did not.
BT_SRC="$MODERN/drivers/swtbt4l"
PLATFORM_HEADER="$MODERN/include/linux/platform_data/skw_platform_data.h"
BT_KO=""
if [[ -d "$BT_SRC" && -f "$PLATFORM_HEADER" ]]; then
    make -C "$KERNEL" M="$BT_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" clean
    if make -j"$JOBS" -C "$KERNEL" M="$BT_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" \
        CONFIG_SKW_BT=m \
        skw_extra_flags="-I$MODERN/include/linux -I$MODERN/include/linux/platform_data -include linux/types.h -include linux/dma-mapping.h -include linux/scatterlist.h -include $PLATFORM_HEADER -DCONFIG_SEEKWAVE_PLD_RELEASE" \
        skw_extra_symbols="$MODERN/Module.symvers" \
        KCFLAGS='-Wno-error' modules; then
        [[ -f "$BT_SRC/skwbt.ko" ]] && BT_KO="$BT_SRC/skwbt.ko"
    fi
    [[ -n "$BT_KO" ]] || echo "[!] Bluetooth module build failed; continuing without it."
else
    echo "[!] Bluetooth source not present; skipping."
fi

echo "[5/5] Verify vermagic and stage"
for ko in "$BSP_KO" "$WIFI_KO" ${BT_KO:+"$BT_KO"}; do
    vm="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
    [[ "$vm" == "$KREL" ]] || die "$(basename "$ko") vermagic '$vm' != kernel '$KREL'"
    if aarch64-linux-gnu-nm -u "$ko" | awk '{print $2}' | grep -Eq '^(skw_|sv6160)' ; then
        # Unresolved Seekwave symbols in the upper modules are expected: they
        # resolve against skw_sdio_lite at load time. Only report them.
        echo "[*] $(basename "$ko") has Seekwave symbol imports (resolved by skw_sdio_lite at load)"
    fi
done

rm -rf "$STAGE"; mkdir -p "$STAGE"
install -m 0644 "$BSP_KO"  "$STAGE/skw_sdio_lite.ko"
install -m 0644 "$WIFI_KO" "$STAGE/skw.ko"
# Load order matters: the SDIO layer must come up before the upper modules,
# which import its symbols.
printf 'skw_sdio_lite\nskw\n' > "$STAGE/c20e-seekwave.conf"
if [[ -n "$BT_KO" ]]; then
    install -m 0644 "$BT_KO" "$STAGE/skwbt.ko"
    # skwbt is deliberately NOT added to c20e-seekwave.conf.
    #
    # Auto-loading it at boot makes its probe run before the chip's BT
    # firmware service has been started, so the probe's HCI Read Local
    # Version times out ("btseekwave_download_nv, read local version err")
    # and hci_register_dev() is never reached. Worse, that failed probe
    # leaves the BT port claimed, after which writing to
    # /proc/skwsdio/bt_service BLOCKS -- which hung the boot and took
    # org.bluez, power profiles and part of the Phosh session with it.
    #
    # c20e-bt-bringup.service starts the chip side first and loads skwbt
    # afterwards, which is the only order that reaches hci0.
    printf 'options skwbt firmware_dir=seekwave\n' > "$STAGE/c20e-skwbt.conf"
fi

echo
echo "[+] Seekwave modules built for kernel $KREL"
sha256sum "$STAGE"/*.ko
echo "[+] Staged in: $STAGE"
echo "[+] build.sh installs these into the rootfs automatically."
echo "[+] To patch an existing card: sudo ./install-c20e-hybrid-seekwave.sh /dev/sdX"
