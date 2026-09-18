#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
ROOTDEV="${3:-/dev/sda4}"
BOOTDEV="${4:-/dev/sda3}"

K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
CAMDTSI="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-camera.dtsi"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-v5.1-integration-$STAMP"

mkdir -p "$REPORT/backups"
exec > >(tee -a "$REPORT/full-build.log") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT

echo "C20e V5.1 hardware integration: $(date -Is)"
echo "Repo:     $REPO"
echo "Rootfs:   $ROOT ($ROOTDEV)"
echo "Boot:     $BOOTDEV"
echo "Kernel:   $K"

[ -f "$DTS" ] || die "C20e DTS missing"
[ -f "$CAMDTSI" ] || die "camera DTSI missing"
[ -f "$K/.config.old" ] || die "known-good .config.old missing"
[ -d "$ROOT/etc" ] || die "$ROOT does not look like mounted rootfs"

ROOTSRC="$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)"
[ "$ROOTSRC" = "$ROOTDEV" ] || die "$ROOT is mounted from '$ROOTSRC', expected '$ROOTDEV'"

BOOTFSTYPE="$(lsblk -n -o FSTYPE "$BOOTDEV" 2>/dev/null || true)"
[ "$BOOTFSTYPE" = "vfat" ] || die "$BOOTDEV is '$BOOTFSTYPE', expected vfat"

if mountpoint -q "$ROOT/boot"; then
    BOOTSRC="$(findmnt -n -o SOURCE --target "$ROOT/boot" 2>/dev/null || true)"
    [ "$BOOTSRC" = "$BOOTDEV" ] || die "$ROOT/boot is already mounted from '$BOOTSRC', expected '$BOOTDEV'"
else
    echo "Mounting the ACTUAL boot partition $BOOTDEV at $ROOT/boot"
    mount "$BOOTDEV" "$ROOT/boot"
fi

echo "Actual boot mount:"
findmnt "$ROOT/boot"
ls -lah "$ROOT/boot" >"$REPORT/boot-partition-before.txt"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/actual-boot-before.sha256" 2>&1 || true
cp -a "$ROOT/boot/Image" "$REPORT/backups/Image.actual-boot.before-v5.1" 2>/dev/null || true
cp -a "$ROOT/boot/rk3562.dtb" "$REPORT/backups/rk3562.dtb.actual-boot.before-v5.1" 2>/dev/null || true
cp -a "$ROOT/boot/extlinux" "$REPORT/backups/extlinux.actual-boot.before-v5.1" 2>/dev/null || true

echo "===== 1/9 recover the failed V5 source edit ====="
PREV="$(find "$REPO" -maxdepth 3 -type f -path '*/c20e-v5-integration-*/backups/c20e.dts.before-v5' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- || true)"
[ -n "$PREV" ] || die "could not locate V5 pre-edit DTS backup"
echo "Restoring C20e DTS from: $PREV"
cp -a "$PREV" "$DTS"
cp -a "$DTS" "$REPORT/backups/c20e.dts.clean-baseline"
cp -a "$CAMDTSI" "$REPORT/backups/camera.dtsi.before-v5.1"

echo "===== 2/9 protected kernel baseline + HUSB320 ====="
cp -a "$K/.config.old" "$K/.config"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost missing"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost unexpectedly enabled"
grep -q '^CONFIG_GS_SC7A20=y' "$K/.config" || die "SC7A20 missing"
grep -q '^CONFIG_GS_DA223=y' "$K/.config" || die "DA223/MIR3DA missing"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "dynamic ftrace unexpectedly enabled"
grep -q '^# CONFIG_WL_ROCKCHIP is not set' "$K/.config" || die "generic Rockchip WLAN unexpectedly enabled"

[ -s "$K/drivers/usb/typec/husb320.c" ] || die "HUSB320 source missing"
grep -q 'config TYPEC_HUSB320' "$K/drivers/usb/typec/Kconfig" || die "HUSB320 Kconfig entry missing"
grep -q 'husb320.o' "$K/drivers/usb/typec/Makefile" || die "HUSB320 Makefile entry missing"

"$K/scripts/config" --file "$K/.config" --enable TYPEC_HUSB320
"$K/scripts/config" --file "$K/.config" --enable VIDEO_OV5648
"$K/scripts/config" --file "$K/.config" --enable VIDEO_DW9714

echo "===== 3/9 exact C20e Seekwave + Bluetooth wiring ====="
python3 - "$DTS" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

def node_block(text, marker):
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f"missing node marker: {marker}")
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"missing opening brace for: {marker}")
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                semi = text.find(";", i)
                if semi < 0:
                    raise SystemExit(f"missing semicolon for: {marker}")
                return start, semi + 1, text[start:semi + 1]
    raise SystemExit(f"unterminated node: {marker}")

# Generic wlan-platdata stays disabled exactly like factory C20e.
a,b,blk = node_block(t, "\twireless-wlan {")
if 'status = "disabled";' not in blk:
    blk = re.sub(r'status = "okay";', 'status = "disabled";', blk)
t = t[:a] + blk + t[b:]

# Seekwave boot node is the active C20e Wi-Fi control path.
a,b,blk = node_block(t, "\tseekwcn_boot: seekwcn_boot {")
blk = blk.replace('status = "disabled";', 'status = "okay";')
blk = blk.replace('gpio_host_wake = <&gpio0 RK_PB4 GPIO_ACTIVE_LOW>;',
                  'gpio_host_wake = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;')
if 'gpio_host_wake = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;' not in blk:
    raise SystemExit("failed to establish factory Seekwave host-wake GPIO0 PC5")
if 'gpio_chip_wake = <&gpio0 RK_PB4 GPIO_ACTIVE_HIGH>;' not in blk:
    raise SystemExit("Seekwave chip-wake is not GPIO0 PB4")
if 'gpio_chip_en = <&gpio0 RK_PB3 GPIO_ACTIVE_HIGH>;' not in blk:
    raise SystemExit("Seekwave chip-enable is not GPIO0 PB3")
t = t[:a] + blk + t[b:]

# Factory C20e Bluetooth has wake PC7 and host-wake PC6, but no reset on PC5.
a,b,blk = node_block(t, "\twireless-bluetooth {")
blk = re.sub(r'\n[ \t]*BT,reset_gpio[^\n]*', '', blk)
if 'BT,wake_gpio     = <&gpio0 RK_PC7 GPIO_ACTIVE_HIGH>;' not in blk:
    raise SystemExit("Bluetooth wake GPIO is not PC7")
if 'BT,wake_host_irq = <&gpio0 RK_PC6 GPIO_ACTIVE_HIGH>;' not in blk:
    raise SystemExit("Bluetooth host-wake GPIO is not PC6")
t = t[:a] + blk + t[b:]

# Enable the SDIO host used by the Seekwave chip.
m = re.search(r'&sdmmc1\s*\{.*?\n\};', t, re.S)
if not m:
    raise SystemExit("missing &sdmmc1")
blk = m.group(0).replace('status = "disabled";', 'status = "okay";')
t = t[:m.start()] + blk + t[m.end():]

p.write_text(t)
PY

grep -q 'gpio_host_wake = <&gpio0 RK_PC5 GPIO_ACTIVE_LOW>;' "$DTS" || die "Seekwave host wake not PC5"
grep -q 'gpio_chip_wake = <&gpio0 RK_PB4 GPIO_ACTIVE_HIGH>;' "$DTS" || die "Seekwave chip wake not PB4"
grep -q 'gpio_chip_en = <&gpio0 RK_PB3 GPIO_ACTIVE_HIGH>;' "$DTS" || die "Seekwave chip enable not PB3"
! grep -q 'BT,reset_gpio.*RK_PC5' "$DTS" || die "stale Bluetooth reset still conflicts with PC5"

echo "===== 4/9 C20e rear camera port ====="
[ -s "$K/drivers/media/i2c/ov5648.c" ] || die "OV5648 driver missing"
[ -s "$K/drivers/media/i2c/dw9714.c" ] || die "DW9714 driver missing"

python3 - "$CAMDTSI" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

def block(text, marker):
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f"missing camera marker: {marker}")
    brace = text.find("{", start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                semi = text.find(";", i)
                return start, semi + 1, text[start:semi + 1]
    raise SystemExit(f"unterminated camera node: {marker}")

def replace_block(text, marker, fn):
    a,b,old = block(text, marker)
    new = fn(old)
    return text[:a] + new + text[b:]

# Rear DPHY0 endpoint: repoint the existing 2-lane slot to the actual OV5648.
def rear_ep(x):
    x = x.replace('remote-endpoint = <&s5k4h5yb_out0>;',
                  'remote-endpoint = <&ov5648_out0>;')
    return x
t = replace_block(t, 'mipi_in_s5k4h5yb: endpoint@1', rear_ep)

# Front DPHY is deliberately disabled until a genuine GC02M1 driver is available.
def dphy4(x):
    x = x.replace('status = "okay";', 'status = "disabled";', 1)
    return x
t = replace_block(t, '&csi2_dphy4 {', dphy4)

# Prevent the old front-OV5648 graph from pointing back at the now-rear OV5648.
def old_front_ep(x):
    x = re.sub(r'\n[ \t]*remote-endpoint = <&ov5648_out0>;', '', x)
    return x
t = replace_block(t, 'mipi_in_ov5648: endpoint@1', old_front_ep)

# Correct autofocus controller at 0x0c.
def fp(x):
    return x.replace('status = "okay";', 'status = "disabled";', 1)
t = replace_block(t, 'fp5510: fp5510@c', fp)

def dw(x):
    return x.replace('status = "disabled";', 'status = "okay";', 1)
t = replace_block(t, 'dw9714: dw9714@c', dw)

# Disable the Doogee-specific active sensors.
def disable_active(x):
    return x.replace('status = "okay";', 'status = "disabled";', 1)
t = replace_block(t, 's5k5e8: s5k5e8@10', disable_active)
t = replace_block(t, 's5k4h5yb: s5k4h5yb@36', disable_active)

# Convert the existing OV5648 candidate into the factory C20e rear sensor.
def ov(x):
    x = x.replace('ov5648: ov5648@35', 'ov5648: ov5648@36', 1)
    x = x.replace('status = "disabled";', 'status = "okay";', 1)
    x = x.replace('reg = <0x35>;', 'reg = <0x36>;', 1)
    x = x.replace('pwdn-gpios = <&gpio3 RK_PC0 GPIO_ACTIVE_HIGH>;',
                  'reset-gpios = <&gpio3 RK_PB5 GPIO_ACTIVE_LOW>;\n'
                  '\t\tpwdn-gpios = <&gpio3 RK_PB4 GPIO_ACTIVE_HIGH>;')
    x = x.replace('rockchip,camera-module-index = <1>;',
                  'rockchip,camera-module-index = <0>;', 1)
    x = x.replace('rockchip,camera-module-facing = "front";',
                  'rockchip,camera-module-facing = "back";', 1)
    if 'lens-focus = <&dw9714>;' not in x:
        x = x.replace('\n\t\tport {', '\n\t\tlens-focus = <&dw9714>;\n\n\t\tport {', 1)
    x = x.replace('remote-endpoint = <&mipi_in_ov5648>;',
                  'remote-endpoint = <&mipi_in_s5k4h5yb>;')
    return x
t = replace_block(t, 'ov5648: ov5648@35', ov)

p.write_text(t)
PY

grep -q 'ov5648: ov5648@36' "$CAMDTSI" || die "OV5648 node was not moved to 0x36"
grep -A30 'ov5648: ov5648@36' "$CAMDTSI" | grep -q 'rockchip,camera-module-facing = "back";' || die "OV5648 not rear-facing"
grep -A30 'ov5648: ov5648@36' "$CAMDTSI" | grep -q 'lens-focus = <&dw9714>;' || die "OV5648 not linked to DW9714"
grep -A16 'dw9714: dw9714@c' "$CAMDTSI" | grep -q 'status = "okay";' || die "DW9714 not enabled"
grep -A16 's5k5e8: s5k5e8@10' "$CAMDTSI" | grep -q 'status = "disabled";' || die "S5K5E8 still active"
grep -A24 's5k4h5yb: s5k4h5yb@36' "$CAMDTSI" | grep -q 'status = "disabled";' || die "S5K4H5YB still active"

if find "$K/drivers/media/i2c" -maxdepth 1 -type f -name 'gc02m1.c' | grep -q .; then
    echo "GC02M1 driver unexpectedly exists; review before enabling front camera." >"$REPORT/front-camera-status.txt"
else
    echo "GC02M1 front camera remains intentionally disabled: no genuine gc02m1.c driver in this kernel." >"$REPORT/front-camera-status.txt"
fi

echo "===== 5/9 quarantine stale camera userspace ====="
systemctl --root="$ROOT" disable camera-isp-setup.service >"$REPORT/camera-service-disable.txt" 2>&1 || true
[ ! -f "$ROOT/etc/systemd/system/camera-isp-setup.service" ] || mv "$ROOT/etc/systemd/system/camera-isp-setup.service" "$ROOT/etc/systemd/system/camera-isp-setup.service.disabled-c20e-v5.1"
[ ! -f "$ROOT/usr/local/sbin/camera-isp-setup" ] || mv "$ROOT/usr/local/sbin/camera-isp-setup" "$ROOT/usr/local/sbin/camera-isp-setup.disabled-c20e-v5.1"
grep -RniE 's5k5e8|camera-isp-setup' "$ROOT/etc/systemd" "$ROOT/usr/local" 2>/dev/null >"$REPORT/stale-camera-userspace-after.txt" || true

echo "===== 6/9 olddefconfig + build ====="
CROSS="$(command -v aarch64-linux-gnu-gcc || true)"
[ -n "$CROSS" ] || die "aarch64-linux-gnu-gcc not found"
CROSS="${CROSS%gcc}"
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"

make -C "$K" olddefconfig

grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost drifted"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost drifted"
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 drifted"
grep -q '^CONFIG_VIDEO_OV5648=y' "$K/.config" || die "OV5648 config missing"
grep -q '^CONFIG_VIDEO_DW9714=y' "$K/.config" || die "DW9714 config missing"

make -C "$K" -j"$(nproc)" Image rockchip/rk3562-rk817-tablet-v10-panfrost.dtb

IMG="$K/arch/arm64/boot/Image"
DTB="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
[ -s "$IMG" ] || die "Image missing"
[ -s "$DTB" ] || die "DTB missing"
[ -s "$K/drivers/usb/typec/husb320.o" ] || die "HUSB320 object missing"

echo "===== 7/9 built DTB validation ====="
dtc -I dtb -O dts -o "$REPORT/built.dts" "$DTB" 2>"$REPORT/dtc-warnings.txt" || die "built DTB decompile failed"

grep -q 'hynetek,husb320' "$REPORT/built.dts" || die "HUSB320 absent from DTB"
grep -q 'ov5648@36' "$REPORT/built.dts" || die "OV5648@36 absent from DTB"
grep -A32 'ov5648@36' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "OV5648@36 not enabled"
grep -q 'dw9714@c' "$REPORT/built.dts" || die "DW9714 absent from DTB"
grep -A24 'dw9714@c' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "DW9714 not enabled in DTB"
grep -A30 's5k5e8@10' "$REPORT/built.dts" | grep -q 'status = "disabled";' || die "S5K5E8 active in DTB"
grep -A36 's5k4h5yb@36' "$REPORT/built.dts" | grep -q 'status = "disabled";' || die "S5K4H5YB active in DTB"
grep -q 'seekwave,sv6160' "$REPORT/built.dts" || die "Seekwave node absent"
! grep -q 'BT,reset_gpio' "$REPORT/built.dts" || die "Bluetooth reset GPIO still present"
sha256sum "$IMG" "$DTB" >"$REPORT/build.sha256"

echo "===== 8/9 deploy to the ACTUAL VFAT boot partition ====="
echo "Boot mount immediately before deployment:"
findmnt "$ROOT/boot"
[ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" = "$BOOTDEV" ] || die "boot partition mount changed unexpectedly"

install -m 0644 "$IMG" "$ROOT/boot/Image"
install -m 0644 "$DTB" "$ROOT/boot/rk3562.dtb"
sync

cmp -s "$IMG" "$ROOT/boot/Image" || die "ACTUAL BOOT Image byte mismatch"
cmp -s "$DTB" "$ROOT/boot/rk3562.dtb" || die "ACTUAL BOOT DTB byte mismatch"

BIMG="$(sha256sum "$IMG" | awk '{print $1}')"
DIMG="$(sha256sum "$ROOT/boot/Image" | awk '{print $1}')"
BDTB="$(sha256sum "$DTB" | awk '{print $1}')"
DDTB="$(sha256sum "$ROOT/boot/rk3562.dtb" | awk '{print $1}')"

[ "$BIMG" = "$DIMG" ] || die "ACTUAL BOOT Image SHA mismatch after sync"
[ "$BDTB" = "$DDTB" ] || die "ACTUAL BOOT DTB SHA mismatch after sync"

sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/actual-boot-after.sha256"

echo "===== 9/9 final report ====="
cp -a "$K/.config" "$REPORT/config-used"
cp -a "$DTS" "$REPORT/c20e.dts.final"
cp -a "$CAMDTSI" "$REPORT/camera.dtsi.final"
diff -u "$REPORT/backups/config-known-good" "$K/.config" >"$REPORT/config.diff" || true
diff -u "$REPORT/backups/c20e.dts.clean-baseline" "$DTS" >"$REPORT/c20e-dts.diff" || true
diff -u "$REPORT/backups/camera.dtsi.before-v5.1" "$CAMDTSI" >"$REPORT/camera-dtsi.diff" || true
grep -E '^(CONFIG_DRM_PANFROST=|# CONFIG_MALI_BIFROST|CONFIG_TYPEC_HUSB320=|CONFIG_VIDEO_OV5648=|CONFIG_VIDEO_DW9714=|CONFIG_GS_SC7A20=|CONFIG_GS_DA223=|# CONFIG_DYNAMIC_FTRACE|# CONFIG_WL_ROCKCHIP)' "$K/.config" >"$REPORT/protected-config.txt" || true
git -C "$K" status --short >"$REPORT/kernel-status.txt" || true
ls -lah "$ROOT/boot" >"$REPORT/boot-partition-after.txt"

echo
echo "PASS: V5.1 build + hardware integration + ACTUAL boot-partition deployment completed."
echo "IMPORTANT: /mnt/boot is confirmed mounted from $BOOTDEV."
echo "GC02M1 front camera remains disabled until a genuine driver is available."
echo "Report: $REPORT"
echo "Do not boot yet; review this report first."
