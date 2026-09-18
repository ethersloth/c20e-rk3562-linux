#!/usr/bin/env bash
set -euo pipefail
REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
FACTORY="$REPO/c20e-analysis/factory-loader/factory-dtb/c20e-factory.dtb"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/c20e-v5-source-audit-$STAMP"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/audit.log") 2>&1
echo "C20e V5 pre-integration source audit: $(date -Is)"
echo "NO kernel/DT/rootfs modifications are performed by this script."
[ -f "$DTS" ] || { echo "ERROR: C20e DTS missing"; exit 1; }
[ -f "$FACTORY" ] || { echo "ERROR: factory DTB missing"; exit 1; }
[ -d "$ROOT/etc" ] || { echo "ERROR: $ROOT is not mounted rootfs"; exit 1; }
dtc -I dtb -O dts -o "$OUT/factory.dts" "$FACTORY" 2>"$OUT/factory-dtc-warnings.txt" || true
cp -a "$DTS" "$OUT/current-c20e.dts"
grep -nEi 'ov5648|gc02m1|dw9714|s5k|csi2_dphy|mipi|rkisp|rkcif|vcc_mipipwr|vcc1v8_dvp|vcc1v2_dvp' "$DTS" >"$OUT/current-camera-lines.txt" || true
grep -nEi 'ov5648|gc02m1|dw9714|s5k|csi2_dphy|mipi|rkisp|rkcif|vcc_mipipwr|vcc1v8_dvp|vcc1v2_dvp' "$OUT/factory.dts" >"$OUT/factory-camera-lines.txt" || true
grep -nEi 'wireless-wlan|seekwcn|skw|sdmmc1|wifi|wlan|host-wake|chip-wake|chip-enable|gpio0' "$DTS" >"$OUT/current-wifi-lines.txt" || true
grep -nEi 'wireless-wlan|seekwcn|skw|sdmmc1|wifi|wlan|host-wake|chip-wake|chip-enable|gpio0' "$OUT/factory.dts" >"$OUT/factory-wifi-lines.txt" || true
grep -nEi 'husb320|usb-role-switch|c20e_usbc_role_sw|c20e_dwc3_role_switch|extcon|u2phy_otg|otg_switch' "$DTS" >"$OUT/current-usb-lines.txt" || true
grep -nEi 'sc7a20|mir3da|da223|gsl3673|touch|battery|charger|rk817' "$DTS" >"$OUT/current-other-hw-lines.txt" || true
grep -nEi 'sc7a20|mir3da|da223|gsl3673|touch|battery|charger|rk817' "$OUT/factory.dts" >"$OUT/factory-other-hw-lines.txt" || true
grep -RniE 'camera-isp-setup|s5k5e8|s5k|chaos|autologin|plymouth|boot-logo|splash' "$ROOT/etc" "$ROOT/usr/local" "$ROOT/usr/share/plymouth" 2>/dev/null >"$OUT/rootfs-stale-and-branding.txt" || true
systemctl --root="$ROOT" is-enabled camera-isp-setup.service >"$OUT/camera-isp-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" cat camera-isp-setup.service >"$OUT/camera-isp-service.txt" 2>&1 || true
find "$ROOT/etc/systemd/system" -maxdepth 4 \( -type f -o -type l \) -print | sort >"$OUT/rootfs-systemd-files.txt"
grep -E '^(CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|CONFIG_DRM_PANFROST=|CONFIG_TYPEC_HUSB320=|CONFIG_GS_SC7A20=|CONFIG_GS_DA223=|# CONFIG_MALI_BIFROST|# CONFIG_WL_ROCKCHIP|# CONFIG_DYNAMIC_FTRACE)' "$K/.config" >"$OUT/current-protected-config.txt" || true
find "$K/drivers/media/i2c" -maxdepth 1 -type f \( -iname '*gc02*' -o -iname '*ov5648*' -o -iname '*dw9714*' -o -iname '*s5k*' \) -printf '%f\n' | sort >"$OUT/camera-driver-files.txt"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" "$K/arch/arm64/boot/Image" "$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb" >"$OUT/boot-hashes.txt" 2>&1 || true
git -C "$K" status --short >"$OUT/kernel-status.txt" 2>&1 || true
tar -C "$REPO" -czf "$OUT.tar.gz" "$(basename "$OUT")"
echo
echo "Audit complete: $OUT.tar.gz"
sha256sum "$OUT.tar.gz"
