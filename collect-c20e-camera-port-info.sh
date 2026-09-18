#!/bin/bash
set -u
REPO="${1:-$PWD}"
OUT="${2:-$PWD/c20e-camera-port-info-$(date +%Y%m%d-%H%M%S)}"
KERNEL="$REPO/src/kernel"
DTS="$KERNEL/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
FACTORY="$REPO/c20e-analysis/factory-loader/factory-dtb/c20e-factory.dtb"
[ -d "$KERNEL" ] || { echo "ERROR: kernel tree not found at $KERNEL"; exit 1; }
mkdir -p "$OUT"
{ echo "=== context ==="; date -Is; git -C "$REPO" status --short 2>/dev/null || true; echo; git -C "$KERNEL" status --short 2>/dev/null || true; } > "$OUT/00-context.txt" 2>&1
if [ -f "$FACTORY" ]; then dtc -I dtb -O dts -o "$OUT/factory-c20e.dts" "$FACTORY" 2>"$OUT/factory-dtc-errors.txt" || true; else echo "Factory DTB not found: $FACTORY" > "$OUT/factory-dtc-errors.txt"; fi
[ -f "$DTS" ] && cp "$DTS" "$OUT/current-c20e-panfrost.dts"
grep -niE 'ov5648|gc02m1|dw9714|s5k4h5|s5k5e8|camera|csi|dphy|mipi|rkcif|rkisp' "$OUT/factory-c20e.dts" > "$OUT/10-factory-camera.txt" 2>/dev/null || true
grep -RniE 'ov5648|gc02m1|dw9714|s5k4h5|s5k5e8|camera|csi|dphy|mipi|rkcif|rkisp' "$DTS" "$KERNEL/arch/arm64/boot/dts/rockchip" > "$OUT/20-current-camera.txt" 2>/dev/null || true
grep -RniE 'ov5648|gc02m1|dw9714|CONFIG_VIDEO_(OV5648|GC02M1|DW9714)|config (VIDEO_)?(OV5648|GC02M1|DW9714)' "$KERNEL/drivers" "$KERNEL/arch" > "$OUT/30-driver-support.txt" 2>/dev/null || true
find "$KERNEL/drivers/media" -type f \( -iname '*ov5648*' -o -iname '*gc02m1*' -o -iname '*dw9714*' \) -print > "$OUT/31-driver-files.txt" 2>/dev/null || true
[ -f "$KERNEL/.config" ] && grep -E 'CONFIG_VIDEO_(OV5648|GC02M1|DW9714)|CONFIG_MEDIA|CONFIG_VIDEO_ROCKCHIP|CONFIG_PHY_ROCKCHIP' "$KERNEL/.config" > "$OUT/40-config.txt" 2>/dev/null || true
grep -niE 'RK_PB4|RK_PB5|RK_PC0|RK_PC1|avdd|dvdd|dovdd|vcc.*cam|supply|mclk|xvclk' "$OUT/factory-c20e.dts" > "$OUT/50-factory-power-gpio-clock.txt" 2>/dev/null || true
grep -niE 'endpoint|remote-endpoint|data-lanes|clock-lanes|port@|ports|csi2|dphy|rkisp|rkcif' "$OUT/factory-c20e.dts" > "$OUT/60-factory-media-graph.txt" 2>/dev/null || true
{ echo "=== media drivers ==="; find "$KERNEL/drivers/media" -type f | grep -Ei 'rockchip|rkisp|rkcif|csi|dphy|ov5648|gc02m1|dw9714' || true; echo "=== bindings ==="; find "$KERNEL/Documentation/devicetree/bindings" -type f | grep -Ei 'ov5648|gc02m1|dw9714|rockchip.*(csi|dphy|isp)|video-interface' || true; } > "$OUT/70-media-inventory.txt" 2>&1
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
echo "Camera-port collection complete."
echo "Archive: $OUT.tar.gz"
echo "No source files, kernel config, DTB, SD card, or tablet storage were modified."
