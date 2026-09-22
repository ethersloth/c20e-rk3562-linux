#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
ROOTDEV="${3:-/dev/sda4}"
BOOTDEV="${4:-/dev/sda3}"

K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
CAMDTSI="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-camera.dtsi"
DTB="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
IMG="$K/arch/arm64/boot/Image"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-v5.2-preboot-$STAMP"
mkdir -p "$REPORT/backups"
exec > >(tee -a "$REPORT/full.log") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT

echo "C20e V5.2 preboot cleanup: $(date -Is)"
echo "Repo: $REPO"
echo "Rootfs: $ROOT ($ROOTDEV)"
echo "Boot: $BOOTDEV"

[ -f "$DTS" ] || die "C20e DTS missing"
[ -f "$CAMDTSI" ] || die "camera DTSI missing"
[ -s "$IMG" ] || die "built Image missing"
[ -d "$ROOT/etc" ] || die "$ROOT does not look like mounted rootfs"

ROOTSRC="$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)"
[ "$ROOTSRC" = "$ROOTDEV" ] || die "$ROOT is '$ROOTSRC', expected '$ROOTDEV'"

[ "$(lsblk -n -o FSTYPE "$BOOTDEV" 2>/dev/null || true)" = "vfat" ] || die "$BOOTDEV is not VFAT"

if mountpoint -q "$ROOT/boot"; then
    [ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" = "$BOOTDEV" ] || die "$ROOT/boot is not $BOOTDEV"
else
    mount "$BOOTDEV" "$ROOT/boot"
fi

echo "Confirmed actual boot partition:"
findmnt "$ROOT/boot"

[ -s "$ROOT/boot/Image" ] || die "actual boot Image missing"
[ -s "$ROOT/boot/rk3562.dtb" ] || die "actual boot DTB missing"

cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image does not match V5.1 built Image; refusing further changes"

cp -a "$DTS" "$REPORT/backups/c20e.dts.before-v5.2"
cp -a "$CAMDTSI" "$REPORT/backups/camera.dtsi.before-v5.2"
cp -a "$ROOT/boot/rk3562.dtb" "$REPORT/backups/rk3562.dtb.actual-boot.before-v5.2"
cp -a "$ROOT/boot/extlinux" "$REPORT/backups/extlinux.before-v5.2" 2>/dev/null || true
cp -a "$ROOT/etc/lightdm/lightdm.conf" "$REPORT/backups/lightdm.conf.before-v5.2" 2>/dev/null || true
cp -a "$ROOT/usr/local/sbin/c20e-firstboot" "$REPORT/backups/c20e-firstboot.before-v5.2" 2>/dev/null || true
cp -a "$ROOT/usr/share/plymouth/themes/rkdebian/splash.png" "$REPORT/backups/rkdebian-splash.before-v5.2.png" 2>/dev/null || true

echo "===== 1/7 camera graph cleanup ====="

python3 - "$CAMDTSI" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

marker = 's5k4h5yb: s5k4h5yb@36'
start = t.find(marker)
if start < 0:
    raise SystemExit("missing disabled s5k4h5yb node")
brace = t.find("{", start)
depth = 0
end = None
for i in range(brace, len(t)):
    if t[i] == "{":
        depth += 1
    elif t[i] == "}":
        depth -= 1
        if depth == 0:
            semi = t.find(";", i)
            end = semi + 1
            break
if end is None:
    raise SystemExit("unterminated s5k4h5yb node")

blk = t[start:end]
if 'status = "disabled";' not in blk:
    raise SystemExit("s5k4h5yb is not disabled; refusing cleanup")

blk = blk.replace('\n\t\t\t\tremote-endpoint = <&mipi_in_s5k4h5yb>;', '')
t = t[:start] + blk + t[end:]
p.write_text(t)
PY

grep -A36 's5k4h5yb: s5k4h5yb@36' "$CAMDTSI" | grep -q 'status = "disabled";' || die "S5K4H5YB status changed"
if grep -A36 's5k4h5yb: s5k4h5yb@36' "$CAMDTSI" | grep -q 'remote-endpoint = <&mipi_in_s5k4h5yb>'; then die "stale S5K4H5YB graph edge remains"; fi
grep -A34 'ov5648: ov5648@36' "$CAMDTSI" | grep -q 'remote-endpoint = <&mipi_in_s5k4h5yb>;' || die "OV5648 rear graph edge missing"

echo "===== 2/7 HUSB320 DT warning cleanup ====="

python3 - "$DTS" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = 'c20e_usbc_role_sw: endpoint@0 {'
new = 'c20e_usbc_role_sw: endpoint {'
if old in t:
    t = t.replace(old, new, 1)
elif new not in t:
    raise SystemExit("C20e USB-C role-switch endpoint not found")
p.write_text(t)
PY

grep -q 'c20e_usbc_role_sw: endpoint {' "$DTS" || die "HUSB320 connector endpoint cleanup failed"

echo "===== 3/7 quarantine stale camera userspace ====="

systemctl --root="$ROOT" disable camera-isp-setup.service >/dev/null 2>&1 || true
find "$ROOT/etc/systemd/system" -type l -lname '*camera-isp-setup.service' -delete 2>/dev/null || true

for f in "$ROOT/usr/local/bin/camera-isp-setup.sh" "$ROOT/usr/local/bin/setup_isp_rear.sh"; do
    if [ -f "$f" ]; then
        mv "$f" "$f.disabled-c20e-v5.2"
    fi
done

grep -RniE 's5k5e8|s5k4h5yb|camera-isp-setup' "$ROOT/etc/systemd/system" "$ROOT/usr/local/bin" 2>/dev/null >"$REPORT/stale-camera-after.txt" || true

echo "===== 4/7 sloth boot branding + firstboot hardening ====="

SLOTH="$ROOT/usr/share/c20e/branding/boot-logo-800x1280.png"
if [ ! -s "$SLOTH" ]; then
    SRC="$REPO/new_boot_screen.png"
    [ -s "$SRC" ] || die "sloth branding image not found in rootfs or $SRC"
    install -d "$ROOT/usr/share/c20e/branding"
    if command -v magick >/dev/null 2>&1; then
        magick "$SRC" -resize 800x1280 -gravity center -background black -extent 800x1280 "$SLOTH"
    elif command -v convert >/dev/null 2>&1; then
        convert "$SRC" -resize 800x1280 -gravity center -background black -extent 800x1280 "$SLOTH"
    else
        cp -a "$SRC" "$SLOTH"
    fi
fi

install -d "$ROOT/usr/share/plymouth/themes/rkdebian"
install -m 0644 "$SLOTH" "$ROOT/usr/share/plymouth/themes/rkdebian/splash.png"

if [ -d "$ROOT/usr/share/plymouth/themes/c20e-sloth" ]; then
    install -m 0644 "$SLOTH" "$ROOT/usr/share/plymouth/themes/c20e-sloth/sloth.png"
fi

systemctl --root="$ROOT" disable rk-session-failsafe.timer rk-session-failsafe.service >/dev/null 2>&1 || true

if [ -f "$ROOT/etc/lightdm/lightdm.conf" ]; then
    sed -i '/^[[:space:]]*autologin-user=/d;/^[[:space:]]*autologin-session=/d' "$ROOT/etc/lightdm/lightdm.conf"
fi

install -d "$ROOT/usr/local/sbin" "$ROOT/var/lib/c20e"

cat >"$ROOT/usr/local/sbin/c20e-firstboot" <<'EOF'
#!/bin/bash
set -euo pipefail
MARK=/var/lib/c20e/firstboot-complete
PRIMARY=/var/lib/c20e/primary-user
[ -e "$MARK" ] && exit 0
exec 9>/run/c20e-firstboot.lock
flock -n 9 || exit 0
clear
echo "Aiprotablet C20e - First Boot Setup"
echo
while :; do
    read -r -p "Create username: " U
    case "$U" in
        ""|root|chaos|*[!a-z0-9_-]*) echo "Use lowercase letters, numbers, _ or -; not root/chaos." ;;
        *) id "$U" >/dev/null 2>&1 && echo "Account already exists." || break ;;
    esac
done
while :; do
    read -r -p "Hostname [c20e]: " H
    H="${H:-c20e}"
    case "$H" in
        *[!A-Za-z0-9-]*|-*|*-) echo "Use letters, numbers and hyphens only." ;;
        *) break ;;
    esac
done
useradd -m -s /bin/bash "$U"
while ! passwd "$U"; do
    echo "Password setup failed; try again."
done
for G in sudo adm audio video render input plugdev netdev dialout; do
    getent group "$G" >/dev/null 2>&1 && usermod -aG "$G" "$U"
done
printf '%s\n' "$U" >"$PRIMARY"
printf '%s\n' "$H" >/etc/hostname
hostnamectl set-hostname "$H" 2>/dev/null || true
mkdir -p "/home/$U/update"
chown -R "$U:$U" "/home/$U/update"
if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i '/^[[:space:]]*autologin-user=/d;/^[[:space:]]*autologin-session=/d' /etc/lightdm/lightdm.conf
fi
rm -f /etc/lightdm/lightdm.conf.d/*autologin* 2>/dev/null || true
rm -f /etc/sudoers.d/10-chaos-nopasswd
if [ -f /usr/local/sbin/rk-powerkey-longpress.py ]; then
    sed -i "s/os\.environ\.get(\"RK_POWERKEY_USER\", \"chaos\")/os.environ.get(\"RK_POWERKEY_USER\", \"$U\")/" /usr/local/sbin/rk-powerkey-longpress.py
fi
if [ -f /usr/local/sbin/rk-audio-resume.sh ]; then
    sed -i "s/RK_AUDIO_USER:-chaos/RK_AUDIO_USER:-$U/g" /usr/local/sbin/rk-audio-resume.sh
fi
if [ -f /usr/local/sbin/rk-apply-update.sh ]; then
    sed -i "s#/home/chaos/update#/home/$U/update#g" /usr/local/sbin/rk-apply-update.sh
fi
systemctl disable rk-session-failsafe.timer rk-session-failsafe.service >/dev/null 2>&1 || true
if id chaos >/dev/null 2>&1; then
    passwd -l chaos >/dev/null 2>&1 || true
    usermod -L chaos >/dev/null 2>&1 || true
fi
passwd -l root >/dev/null 2>&1 || true
touch "$MARK"
systemctl disable c20e-firstboot.service >/dev/null 2>&1 || true
systemctl set-default graphical.target
systemctl enable lightdm.service >/dev/null 2>&1 || true
systemctl enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true
echo
echo "Setup complete for user '$U'. Rebooting into the graphical session..."
sleep 2
systemctl reboot
EOF

chmod 0755 "$ROOT/usr/local/sbin/c20e-firstboot"

cat >"$ROOT/etc/systemd/system/c20e-firstboot.service" <<'EOF'
[Unit]
Description=C20e first-boot account setup
After=local-fs.target systemd-user-sessions.service
Before=getty@tty1.service
ConditionPathExists=!/var/lib/c20e/firstboot-complete

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-firstboot
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

rm -f "$ROOT/var/lib/c20e/firstboot-complete"
systemctl --root="$ROOT" enable c20e-firstboot.service >/dev/null
systemctl --root="$ROOT" set-default multi-user.target >/dev/null
systemctl --root="$ROOT" disable lightdm.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" disable usb-role-manager.service >/dev/null 2>&1 || true

echo "===== 5/7 rebuild + validate DTB ====="

CROSS="$(command -v aarch64-linux-gnu-gcc || true)"
[ -n "$CROSS" ] || die "aarch64-linux-gnu-gcc not found"
CROSS="${CROSS%gcc}"
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"

make -C "$K" rockchip/rk3562-rk817-tablet-v10-panfrost.dtb

[ -s "$DTB" ] || die "rebuilt DTB missing"

dtc -I dtb -O dts -o "$REPORT/built.dts" "$DTB" 2>"$REPORT/dtc-warnings.txt" || die "DTB decompile failed"

grep -q 'hynetek,husb320' "$REPORT/built.dts" || die "HUSB320 missing"
grep -q 'ov5648@36' "$REPORT/built.dts" || die "OV5648@36 missing"
grep -A32 'ov5648@36' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "OV5648 not enabled"
grep -A24 'dw9714@c' "$REPORT/built.dts" | grep -q 'status = "okay";' || die "DW9714 not enabled"
grep -A30 's5k5e8@10' "$REPORT/built.dts" | grep -q 'status = "disabled";' || die "S5K5E8 not disabled"
grep -A36 's5k4h5yb@36' "$REPORT/built.dts" | grep -q 'status = "disabled";' || die "S5K4H5YB not disabled"
grep -q 'seekwave,sv6160' "$REPORT/built.dts" || die "Seekwave missing"
if grep -q 'graph connection to node.*csi2-dphy0' "$REPORT/dtc-warnings.txt"; then die "rear camera graph warning still present"; fi
if grep -q 'husb320@21/connector/ports/port@0/endpoint@0' "$REPORT/dtc-warnings.txt"; then die "HUSB320 endpoint warning still present"; fi

echo "===== 6/7 deploy DTB to actual boot partition ====="

[ "$(findmnt -n -o SOURCE --target "$ROOT/boot")" = "$BOOTDEV" ] || die "actual boot partition is no longer mounted"
install -m 0644 "$DTB" "$ROOT/boot/rk3562.dtb"
sync
cmp -s "$DTB" "$ROOT/boot/rk3562.dtb" || die "actual boot DTB byte mismatch"
cmp -s "$IMG" "$ROOT/boot/Image" || die "actual boot Image changed unexpectedly"

sha256sum "$IMG" "$DTB" >"$REPORT/build.sha256"
sha256sum "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/actual-boot.sha256"

echo "===== 7/7 final preboot validation ====="

systemctl --root="$ROOT" get-default >"$REPORT/default-target.txt"
systemctl --root="$ROOT" is-enabled c20e-firstboot.service >"$REPORT/firstboot-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled lightdm.service >"$REPORT/lightdm-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled c20e-usb-debug.service >"$REPORT/usb-debug-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled serial-getty@ttyGS0.service >"$REPORT/ttygs0-enabled.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled rk-session-failsafe.timer >"$REPORT/session-failsafe.txt" 2>&1 || true
grep -nE 'autologin-user|autologin-session' "$ROOT/etc/lightdm/lightdm.conf" >"$REPORT/lightdm-autologin-after.txt" 2>&1 || true
sha256sum "$SLOTH" "$ROOT/usr/share/plymouth/themes/rkdebian/splash.png" >"$REPORT/sloth-branding.sha256"
cp -a "$DTS" "$REPORT/c20e.dts.final"
cp -a "$CAMDTSI" "$REPORT/camera.dtsi.final"
diff -u "$REPORT/backups/c20e.dts.before-v5.2" "$DTS" >"$REPORT/c20e-dts.diff" || true
diff -u "$REPORT/backups/camera.dtsi.before-v5.2" "$CAMDTSI" >"$REPORT/camera-dtsi.diff" || true

tar -C "$REPO" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"

echo
echo "PASS: C20e V5.2 preboot cleanup completed."
echo "Actual boot Image remains byte-identical to the V5.1 build."
echo "Actual boot DTB is the cleaned V5.2 DTB."
echo "Sloth image now replaces the rkdebian framebuffer splash."
echo "First boot setup is enabled on tty1; USB ttyGS0 recovery remains enabled."
echo "Chaos/root credentials are locked only AFTER a replacement sudo user is created successfully."
echo "Front GC02M1 remains intentionally disabled until a genuine driver exists."
echo "Report archive: $REPORT.tar.gz"
echo "Do not boot until this report is reviewed."
