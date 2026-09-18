#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
ROOTDEV="${3:-/dev/sda4}"
BOOTDEV="${4:-/dev/sda3}"

K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
CAMDTSI="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-camera.dtsi"
GC02M2="$K/drivers/media/i2c/gc02m2.c"
GC02M1="$K/drivers/media/i2c/gc02m1.c"
KCONFIG="$K/drivers/media/i2c/Kconfig"
MAKEFILE="$K/drivers/media/i2c/Makefile"
IMG="$K/arch/arm64/boot/Image"
DTB="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
EXTLINUX="$ROOT/boot/extlinux/extlinux.conf"
FIRSTBOOT="$ROOT/usr/local/sbin/c20e-firstboot"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-v5.3-$STAMP"
mkdir -p "$REPORT/backups"
exec > >(tee -a "$REPORT/full.log") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT

echo "C20e V5.3 GC02M1 + boot-flow integration: $(date -Is)"
echo "Repo:   $REPO"
echo "Rootfs: $ROOT ($ROOTDEV)"
echo "Boot:   $BOOTDEV"
echo "Kernel: $K"

[ -f "$DTS" ] || die "C20e DTS missing"
[ -f "$CAMDTSI" ] || die "camera DTSI missing"
[ -s "$GC02M2" ] || die "Rockchip gc02m2.c reference driver missing"
[ -f "$KCONFIG" ] || die "camera Kconfig missing"
[ -f "$MAKEFILE" ] || die "camera Makefile missing"
[ -f "$FIRSTBOOT" ] || die "C20e firstboot script missing"
[ -d "$ROOT/etc" ] || die "$ROOT does not look like mounted rootfs"

ROOTSRC="$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)"
[ "$ROOTSRC" = "$ROOTDEV" ] || die "$ROOT is mounted from '$ROOTSRC', expected '$ROOTDEV'"

[ "$(lsblk -n -o FSTYPE "$BOOTDEV" 2>/dev/null || true)" = "vfat" ] || die "$BOOTDEV is not VFAT"

if mountpoint -q "$ROOT/boot"; then
    BOOTSRC="$(findmnt -n -o SOURCE --target "$ROOT/boot" 2>/dev/null || true)"
    [ "$BOOTSRC" = "$BOOTDEV" ] || die "$ROOT/boot is '$BOOTSRC', expected '$BOOTDEV'"
else
    mount "$BOOTDEV" "$ROOT/boot"
fi

[ -f "$EXTLINUX" ] || die "extlinux.conf missing from actual boot partition"
[ -s "$ROOT/boot/Image" ] || die "actual boot Image missing"
[ -s "$ROOT/boot/rk3562.dtb" ] || die "actual boot DTB missing"

BOOTPARTUUID="$(blkid -s PARTUUID -o value "$BOOTDEV" 2>/dev/null || true)"
[ -n "$BOOTPARTUUID" ] || die "could not determine boot PARTUUID"

echo "Actual boot partition:"
findmnt "$ROOT/boot"
echo "Boot PARTUUID: $BOOTPARTUUID"

cp -a "$DTS" "$REPORT/backups/c20e.dts.before-v5.3"
cp -a "$CAMDTSI" "$REPORT/backups/camera.dtsi.before-v5.3"
cp -a "$KCONFIG" "$REPORT/backups/Kconfig.before-v5.3"
cp -a "$MAKEFILE" "$REPORT/backups/Makefile.before-v5.3"
cp -a "$FIRSTBOOT" "$REPORT/backups/c20e-firstboot.before-v5.3"
cp -a "$EXTLINUX" "$REPORT/backups/extlinux.conf.before-v5.3"
cp -a "$ROOT/etc/fstab" "$REPORT/backups/fstab.before-v5.3"
cp -a "$ROOT/boot/Image" "$REPORT/backups/Image.actual-boot.before-v5.3"
cp -a "$ROOT/boot/rk3562.dtb" "$REPORT/backups/rk3562.dtb.actual-boot.before-v5.3"
[ ! -f "$GC02M1" ] || cp -a "$GC02M1" "$REPORT/backups/gc02m1.c.before-v5.3"

echo "===== 1/9 create Rockchip V4L2 GC02M1 driver port ====="

python3 - "$GC02M2" "$GC02M1" <<'PY'
import pathlib, re, sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
t = src.read_text()

t = t.replace("gc02m2", "gc02m1").replace("GC02M2", "GC02M1")

t, n = re.subn(r'(#define CHIP_ID\s+)0x02f0', r'\g<1>0x02e0', t, count=1)
if n != 1:
    raise SystemExit("could not patch GC02M1 chip ID")

marker = "static const struct regval gc02m1_global_regs[] = {"
start = t.find(marker)
if start < 0:
    raise SystemExit("gc02m1 global register table not found")
end = t.find("\n};", start)
if end < 0:
    raise SystemExit("gc02m1 global register table unterminated")

blk = t[start:end]
repls = [
    ("\t{0xf5, 0xc0},", "\t{0xf5, 0xe3},"),
    ("\t{0x46, 0x2a},", "\t{0x46, 0x4a},"),
    ("\t{0xd1, 0x40},", "\t{0xd1, 0x60},"),
    ("\t{0xd3, 0xb3},", "\t{0xd3, 0xf3},"),
    ("\t{0xde, 0x1c},", "\t{0xde, 0x1d},"),
    ("\t{0xcd, 0x06},", "\t{0xcd, 0x05},"),
    ("\t{0x15, 0x01},", "\t{0x15, 0x00},"),
]
for old, new in repls:
    c = blk.count(old)
    if c != 1:
        raise SystemExit(f"expected one GC02M1 register delta {old!r}, found {c}")
    blk = blk.replace(old, new, 1)

t = t[:start] + blk + t[end:]

provenance = """/*
 * C20e GC02M1 Rockchip V4L2 port.
 *
 * V4L2/power/control framework derived from Rockchip gc02m2.c (GPL-2.0).
 * GC02M1-specific identification and register deltas are based on the
 * published Thingino/Ingenic gc02m1.c GPLv2 source:
 *   I2C 0x37, chip ID 0x02e0, 24 MHz xvclk,
 *   1600x1200 @ 30 fps, RAW10, one MIPI CSI-2 lane.
 */
"""
spdx = t.find("SPDX-License-Identifier")
spdx_end = t.find("\n", spdx)
if spdx < 0 or spdx_end < 0:
    raise SystemExit("SPDX header not found")
t = t[:spdx_end+1] + provenance + t[spdx_end+1:]

dst.write_text(t)
PY

grep -q 'C20e GC02M1 Rockchip V4L2 port' "$GC02M1" || die "GC02M1 provenance marker missing"
grep -Eq '#define CHIP_ID[[:space:]]+0x02e0' "$GC02M1" || die "GC02M1 chip ID patch missing"
grep -q '{0xf5, 0xe3}' "$GC02M1" || die "GC02M1 register table patch missing"
grep -q '{0x15, 0x00}' "$GC02M1" || die "GC02M1 one-lane MIPI table patch missing"

echo "===== 2/9 wire GC02M1 into Kconfig/Makefile/config ====="

python3 - "$KCONFIG" "$MAKEFILE" <<'PY'
import pathlib, sys

kp = pathlib.Path(sys.argv[1])
mp = pathlib.Path(sys.argv[2])

k = kp.read_text()
if "config VIDEO_GC02M1\n" not in k:
    anchor = 'config VIDEO_GC02M2\n'
    i = k.find(anchor)
    if i < 0:
        raise SystemExit("VIDEO_GC02M2 Kconfig anchor missing")
    block = """config VIDEO_GC02M1
\ttristate "GalaxyCore GC02M1 sensor support"
\tdepends on I2C && VIDEO_DEV
\tdepends on MEDIA_CAMERA_SUPPORT
\tselect MEDIA_CONTROLLER
\tselect VIDEO_V4L2_SUBDEV_API
\tselect V4L2_FWNODE
\thelp
\t  Support for the GalaxyCore GC02M1 2MP RAW10 MIPI sensor.

\t  This C20e port uses one CSI-2 data lane and a 24 MHz xvclk.

\t  To compile this driver as a module, choose M here: the
\t  module will be called gc02m1.

"""
    k = k[:i] + block + k[i:]
    kp.write_text(k)

m = mp.read_text()
line = 'obj-$(CONFIG_VIDEO_GC02M1) += gc02m1.o\n'
if line not in m:
    anchor = 'obj-$(CONFIG_VIDEO_GC02M2) += gc02m2.o\n'
    if anchor not in m:
        raise SystemExit("GC02M2 Makefile anchor missing")
    m = m.replace(anchor, line + anchor, 1)
    mp.write_text(m)
PY

"$K/scripts/config" --file "$K/.config" --enable VIDEO_GC02M1
grep -q '^CONFIG_VIDEO_GC02M1=y' "$K/.config" || die "CONFIG_VIDEO_GC02M1 did not enable"
grep -q 'CONFIG_VIDEO_GC02M1.*gc02m1.o' "$MAKEFILE" || die "GC02M1 Makefile entry missing"
grep -q '^config VIDEO_GC02M1$' "$KCONFIG" || die "GC02M1 Kconfig entry missing"

echo "===== 3/9 enable factory C20e GC02M1 front-camera topology ====="

python3 - "$CAMDTSI" <<'PY'
import pathlib, re, sys

p = pathlib.Path(sys.argv[1])
t = p.read_text()

def get_block(text, marker):
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f"missing marker: {marker}")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"missing opening brace: {marker}")
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                semi = text.find(";", i)
                if semi < 0:
                    raise SystemExit(f"missing semicolon: {marker}")
                return start, semi + 1, text[start:semi + 1]
    raise SystemExit(f"unterminated block: {marker}")

def replace_block(text, marker, new):
    a,b,_ = get_block(text, marker)
    return text[:a] + new + text[b:]

def strip_remote(text, marker, phandle):
    a,b,blk = get_block(text, marker)
    blk = re.sub(rf'\n[ \t]*remote-endpoint = <&{re.escape(phandle)}>;', '', blk)
    return text[:a] + blk + text[b:]

t = strip_remote(t, 'gc5035: gc5035@37', 'mipi_in_gc5035')
t = strip_remote(t, 's5k5e8: s5k5e8@10', 'mipi_in_s5k5e8')

dphy4 = """&csi2_dphy4 {
\tstatus = "okay";

\tports {
\t\t#address-cells = <1>;
\t\t#size-cells = <0>;

\t\tport@0 {
\t\t\treg = <0>;
\t\t\t#address-cells = <1>;
\t\t\t#size-cells = <0>;

\t\t\tmipi_in_gc02m1: endpoint@1 {
\t\t\t\treg = <1>;
\t\t\t\tremote-endpoint = <&gc02m1_out>;
\t\t\t\tdata-lanes = <1>;
\t\t\t};
\t\t};

\t\tport@1 {
\t\t\treg = <1>;
\t\t\t#address-cells = <1>;
\t\t\t#size-cells = <0>;

\t\t\tcsidphy4_out: endpoint@0 {
\t\t\t\treg = <0>;
\t\t\t\tremote-endpoint = <&mipi2_csi2_input>;
\t\t\t\tdata-lanes = <1>;
\t\t\t};
\t\t};
\t};
};"""
t = replace_block(t, '&csi2_dphy4 {', dphy4)

a,b,mipi2 = get_block(t, '&mipi2_csi2 {')
mipi2 = mipi2.replace('data-lanes = <1 2>;', 'data-lanes = <1>;')
t = t[:a] + mipi2 + t[b:]

gc02m1_node = """
\tgc02m1: gc02m1@37 {
\t\tcompatible = "galaxycore,gc02m1";
\t\tstatus = "okay";
\t\treg = <0x37>;
\t\tclocks = <&cru CLK_CAM0_OUT2IO>;
\t\tclock-names = "xvclk";
\t\tpwdn-gpios = <&gpio3 RK_PC0 GPIO_ACTIVE_LOW>;
\t\tavdd-supply = <&vcc_mipipwr>;
\t\tdovdd-supply = <&vcc1v8_dvp>;
\t\tdvdd-supply = <&vcc1v2_dvp>;
\t\trockchip,camera-module-index = <1>;
\t\trockchip,camera-module-facing = "front";
\t\trockchip,camera-module-name = "KYT-8789-V10";
\t\trockchip,camera-module-lens-name = "default";

\t\tport {
\t\t\tgc02m1_out: endpoint {
\t\t\t\tremote-endpoint = <&mipi_in_gc02m1>;
\t\t\t\tdata-lanes = <1>;
\t\t\t};
\t\t};
\t};
"""

if 'gc02m1: gc02m1@37 {' not in t:
    anchor = '\n\tgc5035: gc5035@37 {'
    i = t.find(anchor)
    if i < 0:
        raise SystemExit("gc5035 insertion anchor missing")
    t = t[:i] + gc02m1_node + t[i:]
else:
    t = replace_block(t, 'gc02m1: gc02m1@37 {', gc02m1_node.strip())

p.write_text(t)
PY

grep -q 'gc02m1: gc02m1@37' "$CAMDTSI" || die "GC02M1 DT node missing"
grep -A26 'gc02m1: gc02m1@37' "$CAMDTSI" | grep -q 'compatible = "galaxycore,gc02m1";' || die "GC02M1 compatible missing"
grep -A26 'gc02m1: gc02m1@37' "$CAMDTSI" | grep -q 'pwdn-gpios = <&gpio3 RK_PC0 GPIO_ACTIVE_LOW>;' || die "GC02M1 factory PWDN wiring missing"
grep -A26 'gc02m1: gc02m1@37' "$CAMDTSI" | grep -q 'data-lanes = <1>;' || die "GC02M1 one-lane endpoint missing"
grep -A35 '&csi2_dphy4' "$CAMDTSI" | grep -q 'status = "okay";' || die "DPHY4 not enabled"
grep -A35 '&csi2_dphy4' "$CAMDTSI" | grep -q 'mipi_in_gc02m1' || die "GC02M1 DPHY endpoint missing"

echo "===== 4/9 persistent /boot mount + post-firstboot splash transition ====="

python3 - "$ROOT/etc/fstab" "$BOOTPARTUUID" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
uuid = sys.argv[2]
lines = p.read_text().splitlines()
out = []
for line in lines:
    s = line.strip()
    if s and not s.startswith('#'):
        fields = s.split()
        if len(fields) >= 2 and fields[1] == '/boot':
            continue
    out.append(line)
out.append(f'PARTUUID={uuid}  /boot  vfat  defaults,noatime  0  2')
p.write_text('\n'.join(out).rstrip() + '\n')
PY

grep -q "PARTUUID=$BOOTPARTUUID  /boot  vfat" "$ROOT/etc/fstab" || die "/boot fstab entry missing"

python3 - "$EXTLINUX" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

t = re.sub(r'^default\s+\S+', 'default linux-debug', t, count=1, flags=re.M)

def patch_label(text, label):
    m = re.search(rf'(^label {re.escape(label)}\n.*?)(?=^label |\Z)', text, re.M | re.S)
    if not m:
        raise SystemExit(f"missing extlinux label {label}")
    b = m.group(1)
    b = b.replace(' quiet nosplash ', ' quiet splash ')
    b = b.replace(' nosplash ', ' splash ')
    if ' splash ' not in b:
        b = b.replace(' append ', ' append splash ', 1)
    return text[:m.start(1)] + b + text[m.end(1):]

t = patch_label(t, 'linux')
t = patch_label(t, 'linux-fallback')
p.write_text(t)
PY

grep -q '^default linux-debug$' "$EXTLINUX" || die "first boot is not linux-debug"
grep -A3 '^label linux$' "$EXTLINUX" | grep -q ' splash ' || die "normal linux entry lacks splash"
if grep -A3 '^label linux$' "$EXTLINUX" | grep -q 'nosplash'; then die "normal linux entry still has nosplash"; fi

python3 - "$FIRSTBOOT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

tag = '# c20e-v5.3-boot-transition'
if tag not in t:
    marker = 'if id chaos >/dev/null 2>&1; then'
    i = t.find(marker)
    if i < 0:
        raise SystemExit("firstboot account-lock marker missing")
    block = """# c20e-v5.3-boot-transition
if ! mountpoint -q /boot; then
    echo "ERROR: /boot is not mounted; refusing to retire the recovery account."
    exit 1
fi
if [ ! -f /boot/extlinux/extlinux.conf ]; then
    echo "ERROR: /boot/extlinux/extlinux.conf is missing."
    exit 1
fi
sed -i 's/^default .*/default linux/' /boot/extlinux/extlinux.conf
sync

"""
    t = t[:i] + block + t[i:]

p.write_text(t)
PY

chmod 0755 "$FIRSTBOOT"
grep -q '# c20e-v5.3-boot-transition' "$FIRSTBOOT" || die "firstboot boot transition missing"
grep -q "default linux" "$FIRSTBOOT" || die "firstboot default-linux transition missing"

echo "===== 5/9 protected config validation + olddefconfig ====="

grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost missing before build"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost unexpectedly enabled"
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 missing"
grep -q '^CONFIG_GS_SC7A20=y' "$K/.config" || die "SC7A20 missing"
grep -q '^CONFIG_GS_DA223=y' "$K/.config" || die "DA223/MIR3DA missing"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "dynamic ftrace unexpectedly enabled"
grep -q '^# CONFIG_WL_ROCKCHIP is not set' "$K/.config" || die "generic Rockchip WLAN unexpectedly enabled"

CROSS="$(command -v aarch64-linux-gnu-gcc || true)"
[ -n "$CROSS" ] || die "aarch64-linux-gnu-gcc not found"
CROSS="${CROSS%gcc}"
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"

make -C "$K" olddefconfig

grep -q '^CONFIG_VIDEO_GC02M1=y' "$K/.config" || die "GC02M1 lost during olddefconfig"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost drifted"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost drifted"
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 drifted"

echo "===== 6/9 build Image + DTB with GC02M1 ====="

make -C "$K" -j"$(nproc)" Image rockchip/rk3562-rk817-tablet-v10-panfrost.dtb

[ -s "$IMG" ] || die "built Image missing"
[ -s "$DTB" ] || die "built DTB missing"
[ -s "$K/drivers/media/i2c/gc02m1.o" ] || die "GC02M1 object did not build"
[ -s "$K/drivers/usb/typec/husb320.o" ] || die "HUSB320 object missing"

echo "===== 7/9 validate built GC02M1 DT graph ====="

dtc -I dtb -O dts -o "$REPORT/built.dts" "$DTB" 2>"$REPORT/dtc-warnings.txt" || die "DTB decompile failed"

grep -q 'compatible = "galaxycore,gc02m1";' "$REPORT/built.dts" || die "GC02M1 compatible absent from DTB"
grep -q 'gc02m1@37' "$REPORT/built.dts" || die "GC02M1@37 absent from DTB"
grep -A28 'gc02m1@37' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "GC02M1 not enabled in DTB"
grep -A28 'gc02m1@37' "$REPORT/built.dts" | grep -Eq 'data-lanes = <0x0*1>;' || die "GC02M1 DTB endpoint is not one lane"
grep -q 'hynetek,husb320' "$REPORT/built.dts" || die "HUSB320 absent from DTB"
grep -q 'ov5648@36' "$REPORT/built.dts" || die "rear OV5648 absent from DTB"
grep -A32 'ov5648@36' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "rear OV5648 not enabled"
grep -q 'seekwave,sv6160' "$REPORT/built.dts" || die "Seekwave absent from DTB"

if grep -Ei 'graph connection.*(gc02m1|csi2-dphy4|mipi2)' "$REPORT/dtc-warnings.txt"; then
    die "front-camera graph warning remains"
fi

sha256sum "$IMG" "$DTB" "$GC02M1" >"$REPORT/build.sha256"

echo "===== 8/9 deploy to actual VFAT boot partition ====="

[ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" = "$BOOTDEV" ] || die "actual boot partition is no longer mounted"

install -m 0644 "$IMG" "$ROOT/boot/Image"
install -m 0644 "$DTB" "$ROOT/boot/rk3562.dtb"
sync

cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image byte mismatch"
cmp -s "$DTB" "$ROOT/boot/rk3562.dtb" || die "actual boot DTB byte mismatch"

sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/actual-boot.sha256"

echo "===== 9/9 final report ====="

cp -a "$K/.config" "$REPORT/config-used"
cp -a "$GC02M1" "$REPORT/gc02m1.c"
cp -a "$CAMDTSI" "$REPORT/camera.dtsi.final"
cp -a "$EXTLINUX" "$REPORT/extlinux.conf.final"
cp -a "$FIRSTBOOT" "$REPORT/c20e-firstboot.final"
cp -a "$ROOT/etc/fstab" "$REPORT/fstab.final"

diff -u "$REPORT/backups/Kconfig.before-v5.3" "$KCONFIG" >"$REPORT/Kconfig.diff" || true
diff -u "$REPORT/backups/Makefile.before-v5.3" "$MAKEFILE" >"$REPORT/Makefile.diff" || true
diff -u "$REPORT/backups/camera.dtsi.before-v5.3" "$CAMDTSI" >"$REPORT/camera-dtsi.diff" || true
diff -u "$REPORT/backups/extlinux.conf.before-v5.3" "$EXTLINUX" >"$REPORT/extlinux.diff" || true
diff -u "$REPORT/backups/c20e-firstboot.before-v5.3" "$FIRSTBOOT" >"$REPORT/firstboot.diff" || true
diff -u "$REPORT/backups/fstab.before-v5.3" "$ROOT/etc/fstab" >"$REPORT/fstab.diff" || true

grep -E '^(CONFIG_DRM_PANFROST=|# CONFIG_MALI_BIFROST|CONFIG_TYPEC_HUSB320=|CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|CONFIG_VIDEO_GC02M1=|CONFIG_GS_SC7A20=|CONFIG_GS_DA223=|# CONFIG_DYNAMIC_FTRACE|# CONFIG_WL_ROCKCHIP)' "$K/.config" >"$REPORT/protected-config.txt" || true
git -C "$K" status --short >"$REPORT/kernel-status.txt" || true
systemctl --root="$ROOT" get-default >"$REPORT/default-target.txt"
systemctl --root="$ROOT" is-enabled c20e-firstboot.service >"$REPORT/firstboot-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled c20e-usb-debug.service >"$REPORT/usb-debug-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service >"$REPORT/ttygs0-enabled.txt" 2>&1 || true

tar -C "$REPO" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"

echo
echo "PASS: C20e V5.3 completed."
echo " - GC02M1 Rockchip V4L2 port compiled into the kernel."
echo " - Front GC02M1@0x37 is enabled on one CSI-2 lane."
echo " - Rear OV5648/DW9714, HUSB320, Panfrost and Seekwave validation passed."
echo " - /boot will mount persistently by PARTUUID."
echo " - First boot remains linux-debug for the tty1 account wizard."
echo " - Successful firstboot switches extlinux default to normal 'linux'."
echo " - Normal linux/fallback entries use the sloth splash path."
echo "Report archive: $REPORT.tar.gz"
echo "Do not boot until the report is reviewed."
