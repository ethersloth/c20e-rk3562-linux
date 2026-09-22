#!/usr/bin/env bash
set -euo pipefail
REPO="${1:-$PWD}"; ROOT="${2:-/mnt}"; K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
STAMP="$(date +%Y%m%d-%H%M%S)"; REPORT="$REPO/c20e-v5-integration-$STAMP"
mkdir -p "$REPORT/backups"; exec > >(tee -a "$REPORT/full-build.log") 2>&1
die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT
echo "C20e V5 hardware integration: $(date -Is)"
[ -f "$DTS" ] || die "C20e DTS missing"; [ -f "$K/.config.old" ] || die ".config.old missing"; [ -d "$ROOT/etc" ] || die "$ROOT not mounted"
CROSS="$(command -v aarch64-linux-gnu-gcc || true)"; [ -n "$CROSS" ] || die "cross compiler missing"; CROSS="${CROSS%gcc}"
cp -a "$DTS" "$REPORT/backups/c20e.dts.before-v5"; cp -a "$K/.config.old" "$REPORT/backups/config-known-good"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/deployed-before.sha256" 2>&1 || true

echo "===== 1/8 protected baseline + HUSB320 ====="
cp -a "$K/.config.old" "$K/.config"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost missing"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost enabled"
grep -q '^CONFIG_GS_SC7A20=y' "$K/.config" || die "SC7A20 missing"
grep -q '^CONFIG_GS_DA223=y' "$K/.config" || die "DA223 missing"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "dynamic ftrace enabled"
[ -s "$K/drivers/usb/typec/husb320.c" ] || die "HUSB320 source missing"
grep -q 'config TYPEC_HUSB320' "$K/drivers/usb/typec/Kconfig" || die "HUSB320 Kconfig missing"
grep -q 'husb320.o' "$K/drivers/usb/typec/Makefile" || die "HUSB320 Makefile missing"
"$K/scripts/config" --file "$K/.config" --enable TYPEC_HUSB320

echo "===== 2/8 exact C20e Wi-Fi wiring ====="
python3 - "$DTS" <<'PY'
import sys,re,pathlib
p=pathlib.Path(sys.argv[1]); t=p.read_text()
t=t.replace('WIFI,host_wake_irq = <&gpio0 RK_PB4 GPIO_ACTIVE_HIGH>;','WIFI,host_wake_irq = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;')
t=t.replace('gpio_host_wake = <&gpio0 RK_PB4 GPIO_ACTIVE_LOW>;','gpio_host_wake = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;')
t=t.replace('rockchip,pins = <0 RK_PB4 RK_FUNC_GPIO &pcfg_pull_down>;','rockchip,pins = <0 RK_PC5 RK_FUNC_GPIO &pcfg_pull_up>;')
for marker in ('wireless-wlan {','seekwcn_boot: seekwcn_boot {'):
    i=t.find(marker)
    if i<0: raise SystemExit("missing "+marker)
    j=t.find('};',i); b=t[i:j].replace('status = "disabled";','status = "okay";'); t=t[:i]+b+t[j:]
m=re.search(r'&sdmmc1\s*\{.*?\n\};',t,re.S)
if not m: raise SystemExit("missing &sdmmc1")
t=t[:m.start()]+m.group(0).replace('status = "disabled";','status = "okay";')+t[m.end():]
p.write_text(t)
PY
grep -q 'WIFI,host_wake_irq = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;' "$DTS" || die "WLAN host wake fix failed"
grep -q 'gpio_host_wake = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;' "$DTS" || die "Seekwave host wake fix failed"

echo "===== 3/8 remove obsolete S5K5E8 userspace ====="
systemctl --root="$ROOT" disable camera-isp-setup.service >"$REPORT/camera-service-disable.txt" 2>&1 || true
[ ! -f "$ROOT/etc/systemd/system/camera-isp-setup.service" ] || mv "$ROOT/etc/systemd/system/camera-isp-setup.service" "$ROOT/etc/systemd/system/camera-isp-setup.service.disabled-c20e-v5"
[ ! -f "$ROOT/usr/local/sbin/camera-isp-setup" ] || mv "$ROOT/usr/local/sbin/camera-isp-setup" "$ROOT/usr/local/sbin/camera-isp-setup.disabled-c20e-v5"
grep -RniE 's5k5e8|camera-isp-setup' "$ROOT/etc/systemd" "$ROOT/usr/local" 2>/dev/null >"$REPORT/stale-camera-after.txt" || true

echo "===== 4/8 rear OV5648 + DW9714 prerequisites ====="
[ -s "$K/drivers/media/i2c/ov5648.c" ] || die "OV5648 driver missing"; [ -s "$K/drivers/media/i2c/dw9714.c" ] || die "DW9714 driver missing"
if find "$K/drivers/media/i2c" -maxdepth 1 -iname 'gc02m1.c' | grep -q .; then echo "GC02M1 driver present" >"$REPORT/front-camera-status.txt"; else echo "GC02M1 intentionally disabled: matching driver absent" >"$REPORT/front-camera-status.txt"; fi
"$K/scripts/config" --file "$K/.config" --enable VIDEO_OV5648; "$K/scripts/config" --file "$K/.config" --enable VIDEO_DW9714
for label in i2c4 csi2_dphy0 mipi0_csi2; do grep -RqsE "(^|[[:space:]])${label}:" "$K/arch/arm64/boot/dts/rockchip" || die "camera label $label not found; refusing guessed topology"; done
CAMCLK="$(grep -RhsA18 'ov5648@' "$K/arch/arm64/boot/dts/rockchip" | grep -m1 -E '^[[:space:]]*clocks = <&cru [A-Za-z0-9_]+>;' | sed -E 's/.*<&cru ([A-Za-z0-9_]+)>.*/\1/' || true)"
[ -n "$CAMCLK" ] || die "could not derive OV5648 xvclk macro"
echo "Derived OV5648 clock: $CAMCLK"

python3 - "$DTS" "$CAMCLK" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1]); clk=sys.argv[2]; t=p.read_text()
if 'c20e-camera-v5' not in t:
    t += f'''
/* c20e-camera-v5: factory rear camera */
vcc_mipipwr: vcc-mipipwr-regulator {{
 compatible = "regulator-fixed";
 gpio = <&gpio3 RK_PB3 GPIO_ACTIVE_HIGH>;
 regulator-name = "vcc_mipipwr";
 enable-active-high;
}};
&i2c4 {{
 status = "okay";
 dw9714: dw9714@c {{
  compatible = "dongwoon,dw9714"; reg = <0x0c>; status = "okay";
  rockchip,camera-module-index = <0>; rockchip,vcm-start-current = <5>;
  rockchip,vcm-rated-current = <90>; rockchip,vcm-step-mode = <5>;
  rockchip,camera-module-facing = "back"; xsd-gpios = <&gpio3 RK_PC1 GPIO_ACTIVE_HIGH>;
 }};
 ov5648: ov5648@36 {{
  compatible = "ovti,ov5648"; reg = <0x36>; status = "okay";
  clocks = <&cru {clk}>; clock-names = "xvclk";
  reset-gpios = <&gpio3 RK_PB5 GPIO_ACTIVE_LOW>; pwdn-gpios = <&gpio3 RK_PB4 GPIO_ACTIVE_HIGH>;
  avdd-supply = <&vcc_mipipwr>; dovdd-supply = <&vcc1v8_dvp>; dvdd-supply = <&vcc1v2_dvp>;
  rockchip,camera-module-index = <0>; rockchip,camera-module-facing = "back";
  rockchip,camera-module-name = "HS5885-BNSM1018-V01"; rockchip,camera-module-lens-name = "default";
  lens-focus = <&dw9714>;
  port {{ ov5648_out: endpoint {{ remote-endpoint = <&mipi_in_ov5648>; data-lanes = <1 2>; }}; }};
 }};
}};
&csi2_dphy0 {{
 status = "okay";
 ports {{ #address-cells = <1>; #size-cells = <0>;
  port@0 {{ reg = <0>; #address-cells = <1>; #size-cells = <0>;
   mipi_in_ov5648: endpoint@1 {{ reg = <1>; remote-endpoint = <&ov5648_out>; data-lanes = <1 2>; }};
  }};
  port@1 {{ reg = <1>; #address-cells = <1>; #size-cells = <0>;
   csidphy0_out: endpoint@0 {{ reg = <0>; remote-endpoint = <&mipi0_csi2_input>; data-lanes = <1 2>; }};
  }};
 }};
}};
&mipi0_csi2 {{
 status = "okay";
 ports {{ #address-cells = <1>; #size-cells = <0>;
  port@0 {{ reg = <0>; #address-cells = <1>; #size-cells = <0>;
   mipi0_csi2_input: endpoint@1 {{ reg = <1>; remote-endpoint = <&csidphy0_out>; data-lanes = <1 2>; }};
  }};
 }};
}};
'''
p.write_text(t)
PY

echo "===== 5/8 olddefconfig + build ====="
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"
make -C "$K" olddefconfig
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost drifted"; grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost drifted"; grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 drifted"
make -C "$K" -j"$(nproc)" Image rockchip/rk3562-rk817-tablet-v10-panfrost.dtb
IMG="$K/arch/arm64/boot/Image"; DTB="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
[ -s "$IMG" ] || die "Image missing"; [ -s "$DTB" ] || die "DTB missing"; [ -s "$K/drivers/usb/typec/husb320.o" ] || die "HUSB320 object missing"

echo "===== 6/8 DTB validation ====="
dtc -I dtb -O dts -o "$REPORT/built.dts" "$DTB" 2>"$REPORT/dtc-warnings.txt" || die "DTB decompile failed"
grep -q 'hynetek,husb320' "$REPORT/built.dts" || die "HUSB320 absent"; grep -q 'ovti,ov5648' "$REPORT/built.dts" || die "OV5648 absent"; grep -q 'dongwoon,dw9714' "$REPORT/built.dts" || die "DW9714 absent"; grep -q 'seekwave,sv6160' "$REPORT/built.dts" || die "Seekwave absent"
if grep -q 'galaxycore,gc02m1' "$REPORT/built.dts"; then die "GC02M1 unexpectedly enabled without driver"; fi
sha256sum "$IMG" "$DTB" >"$REPORT/build.sha256"

echo "===== 7/8 byte-exact deployment ====="
cp -a "$ROOT/boot/Image" "$REPORT/backups/Image.before-v5"; cp -a "$ROOT/boot/rk3562.dtb" "$REPORT/backups/rk3562.dtb.before-v5"
install -m 0644 "$IMG" "$ROOT/boot/Image"; install -m 0644 "$DTB" "$ROOT/boot/rk3562.dtb"; sync
cmp -s "$IMG" "$ROOT/boot/Image" || die "DEPLOYED IMAGE BYTE MISMATCH"; cmp -s "$DTB" "$ROOT/boot/rk3562.dtb" || die "DEPLOYED DTB BYTE MISMATCH"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/deployed-after.sha256"
[ "$(sha256sum "$IMG"|awk '{print $1}')" = "$(sha256sum "$ROOT/boot/Image"|awk '{print $1}')" ] || die "Image SHA mismatch after sync"
[ "$(sha256sum "$DTB"|awk '{print $1}')" = "$(sha256sum "$ROOT/boot/rk3562.dtb"|awk '{print $1}')" ] || die "DTB SHA mismatch after sync"

echo "===== 8/8 final report ====="
cp -a "$K/.config" "$REPORT/config-used"; diff -u "$REPORT/backups/config-known-good" "$K/.config" >"$REPORT/config.diff" || true
grep -E '^(CONFIG_DRM_PANFROST=|# CONFIG_MALI_BIFROST|CONFIG_TYPEC_HUSB320=|CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|CONFIG_GS_SC7A20=|CONFIG_GS_DA223=|# CONFIG_DYNAMIC_FTRACE|# CONFIG_WL_ROCKCHIP)' "$K/.config" >"$REPORT/protected-config.txt" || true
git -C "$K" status --short >"$REPORT/kernel-status.txt" || true
echo "PASS: V5 build and byte-exact deployment completed."
echo "GC02M1 front camera remains intentionally disabled until a genuine driver is available."
echo "Report: $REPORT"
