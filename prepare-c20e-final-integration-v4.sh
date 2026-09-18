#!/bin/bash
set -euo pipefail
RUNLOG=""
on_exit(){ rc=$?; if [ -n "${RUNLOG:-}" ]; then printf '\n[%s] EXIT rc=%s\n' "$(date -Is)" "$rc" | tee -a "$RUNLOG"; fi; }
trap on_exit EXIT
REPO="${1:-$PWD}"
ROOT="${2:-/mnt}"
LOGO="${3:-$REPO/new_boot_screen.png}"
K="$REPO/src/kernel"
DTS="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dts"
DTB="$K/arch/arm64/boot/dts/rockchip/rk3562-rk817-tablet-v10-panfrost.dtb"
FACTORY="$REPO/c20e-analysis/factory-loader/factory-dtb/c20e-factory.dtb"
GOODCFG="$K/.config.before-c20e-good-husb320"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-final-v2-$STAMP"
JOBS="${JOBS:-$(nproc)}"
die(){ echo "ERROR: $*" >&2; exit 1; }
note(){ printf '\n===== %s =====\n' "$*"; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -d "$K" ] || die "kernel tree missing"
[ -f "$DTS" ] || die "C20e DTS missing"
[ -f "$FACTORY" ] || die "factory DTB missing"
[ -f "$LOGO" ] || die "logo missing: $LOGO"
[ -d "$ROOT/etc" ] || die "$ROOT is not mounted C20e rootfs"
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then CROSS="$(command -v aarch64-linux-gnu-gcc)"; CROSS="${CROSS%gcc}"; else die "aarch64-linux-gnu-gcc not found; install Fedora gcc-aarch64-linux-gnu first"; fi
export ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config"
mkdir -p "$REPORT/backups"
RUNLOG="$REPORT/full-build.log"
exec > >(tee -a "$RUNLOG") 2>&1
echo "C20e integration V4 started: $(date -Is)"
echo "Repository: $REPO"
echo "Rootfs: $ROOT"
echo "Kernel: $K"
echo "Toolchain prefix: $CROSS"
note "1/9 - Preserve state and restore controlled kernel config"
cp -a "$DTS" "$REPORT/backups/"
cp -a "$K/.config" "$REPORT/backups/config-at-start" 2>/dev/null || true
GOODCFG="$K/.config.old"
[ -f "$GOODCFG" ] || die "known-good baseline missing: $GOODCFG"
echo "Using explicit known-good baseline: $GOODCFG"
cp -a "$GOODCFG" "$REPORT/backups/config-known-good-baseline"
cp -a "$GOODCFG" "$K/.config"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "baseline lacks Panfrost"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "baseline enables Bifrost"
grep -q '^CONFIG_GS_SC7A20=y' "$K/.config" || die "baseline lost SC7A20"
grep -q '^CONFIG_GS_DA223=y' "$K/.config" || die "baseline lost DA223/MIR3DA support"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "baseline unexpectedly enables dynamic ftrace"
grep -q '^# CONFIG_WL_ROCKCHIP is not set' "$K/.config" || die "baseline unexpectedly enables generic Rockchip WLAN"
"$K/scripts/config" --file "$K/.config" --enable DRM
"$K/scripts/config" --file "$K/.config" --enable DRM_SCHED
"$K/scripts/config" --file "$K/.config" --enable DRM_GEM_SHMEM_HELPER
"$K/scripts/config" --file "$K/.config" --enable DRM_PANFROST
"$K/scripts/config" --file "$K/.config" --disable MALI_BIFROST
"$K/scripts/config" --file "$K/.config" --enable TYPEC_HUSB320
grep -q 'config TYPEC_HUSB320' "$K/drivers/usb/typec/Kconfig" || die "HUSB320 Kconfig backport missing"
grep -Eq 'husb320\.o' "$K/drivers/usb/typec/Makefile" || die "HUSB320 Makefile backport missing"
[ -s "$K/drivers/usb/typec/husb320.c" ] || die "HUSB320 driver source missing"
grep -q 'compatible = "hynetek,husb320"' "$DTS" || die "C20e HUSB320 DT node missing"
grep -q 'usb-role-switch' "$DTS" || die "C20e DWC3 usb-role-switch missing"
grep -q 'c20e_usbc_role_sw' "$DTS" || die "C20e USB-C connector endpoint missing"
grep -q 'c20e_dwc3_role_switch' "$DTS" || die "C20e DWC3 endpoint missing"
"$K/scripts/config" --file "$K/.config" --enable VIDEO_OV5648
"$K/scripts/config" --file "$K/.config" --enable VIDEO_DW9714
make -C "$K" ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" olddefconfig
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "olddefconfig removed Panfrost"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "olddefconfig enabled Bifrost"
cp -a "$K/.config" "$REPORT/config-used-for-build"
diff -u "$REPORT/backups/config-known-good-baseline" "$K/.config" >"$REPORT/config-baseline-to-build.diff" || true
printf '%s\n' "Protected baseline:" >"$REPORT/protected-config.txt"
grep -E '^(CONFIG_DRM_PANFROST=|CONFIG_GS_SC7A20=|CONFIG_GS_DA223=|# CONFIG_MALI_BIFROST|# CONFIG_DYNAMIC_FTRACE|# CONFIG_WL_ROCKCHIP|CONFIG_TYPEC_HUSB320=)' "$K/.config" >>"$REPORT/protected-config.txt"
note "2/9 - Validate factory hardware"
dtc -I dtb -O dts -o "$REPORT/factory.dts" "$FACTORY" 2>"$REPORT/factory-dtc-warnings.txt"
grep -q 'compatible = "ovti,ov5648"' "$REPORT/factory.dts" || die "OV5648 missing from factory DT"
grep -q 'compatible = "galaxycore,gc02m1"' "$REPORT/factory.dts" || die "GC02M1 missing from factory DT"
grep -q 'compatible = "dongwoon,dw9714"' "$REPORT/factory.dts" || die "DW9714 missing from factory DT"
note "3/9 - Front camera driver gate"
if [ ! -f "$K/drivers/media/i2c/gc02m1.c" ]; then
  cat >"$REPORT/GC02M1-BLOCKER.txt" <<EOF
The factory DT proves this tablet uses GalaxyCore GC02M1.
The Rockchip develop-6.1 kernel tree does not provide drivers/media/i2c/gc02m1.c.
Public upstream Linux and Rockchip develop-6.1 also do not currently provide a GC02M1 V4L2 driver.
No substitute GC02M2/GC2145 driver was used because sensor register programming is not interchangeable.
EOF
  echo "GC02M1 driver is unavailable; recording blocker rather than fabricating sensor code."
fi
note "4/9 - Build with correct AArch64 toolchain"
echo "CROSS_COMPILE=$CROSS" | tee "$REPORT/toolchain.txt"
"$CROSS"gcc --version | head -1 | tee -a "$REPORT/toolchain.txt"
make -C "$K" ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" -j"$JOBS" Image
make -C "$K" ARCH=arm64 CROSS_COMPILE="$CROSS" KCONFIG_CONFIG="$K/.config" -j"$JOBS" rockchip/rk3562-rk817-tablet-v10-panfrost.dtb
[ -s "$K/arch/arm64/boot/Image" ] || die "Image missing"
[ -s "$DTB" ] || die "DTB missing"
grep -q '^CONFIG_DRM_PANFROST=y' "$K/.config" || die "Panfrost lost"
grep -q '^# CONFIG_MALI_BIFROST is not set' "$K/.config" || die "Bifrost enabled"
grep -q '^CONFIG_TYPEC_HUSB320=y' "$K/.config" || die "HUSB320 lost"
[ -s "$K/drivers/usb/typec/husb320.o" ] || die "HUSB320 object was not built"
grep -q '^CONFIG_GS_SC7A20=y' "$K/.config" || die "SC7A20 lost during build"
grep -q '^CONFIG_GS_DA223=y' "$K/.config" || die "DA223/MIR3DA support lost during build"
grep -q '^# CONFIG_DYNAMIC_FTRACE is not set' "$K/.config" || die "dynamic ftrace drifted on"
grep -q '^# CONFIG_WL_ROCKCHIP is not set' "$K/.config" || die "generic Rockchip WLAN drifted on"
{
 echo "HUSB320 backport validation: PASS"
 echo "source: drivers/usb/typec/husb320.c"
 echo "object: drivers/usb/typec/husb320.o"
 grep '^CONFIG_TYPEC_HUSB320=' "$K/.config"
 grep -n 'config TYPEC_HUSB320' "$K/drivers/usb/typec/Kconfig" | head -1
 grep -n 'husb320.o' "$K/drivers/usb/typec/Makefile" | head -1
 grep -n 'compatible = "hynetek,husb320"' "$DTS" | head -1
 grep -n 'usb-role-switch' "$DTS" | head -1
} >"$REPORT/husb320-validation.txt"
note "5/9 - Install sloth branding"
install -d "$ROOT/usr/share/c20e/branding"
install -m 0644 "$LOGO" "$ROOT/usr/share/c20e/branding/boot-logo.png"
if command -v convert >/dev/null 2>&1; then convert "$LOGO" -resize 800x1280 -gravity center -background black -extent 800x1280 "$ROOT/usr/share/c20e/branding/boot-logo-800x1280.png"; else cp -a "$LOGO" "$ROOT/usr/share/c20e/branding/boot-logo-800x1280.png"; fi
if [ -d "$ROOT/usr/share/plymouth/themes" ]; then
 install -d "$ROOT/usr/share/plymouth/themes/c20e-sloth"
 cp "$ROOT/usr/share/c20e/branding/boot-logo-800x1280.png" "$ROOT/usr/share/plymouth/themes/c20e-sloth/sloth.png"
 printf '%s\n' '[Plymouth Theme]' 'Name=C20e Sloth' 'Description=C20e Sloth boot splash' 'ModuleName=script' '' '[script]' 'ImageDir=/usr/share/plymouth/themes/c20e-sloth' 'ScriptFile=/usr/share/plymouth/themes/c20e-sloth/c20e-sloth.script' >"$ROOT/usr/share/plymouth/themes/c20e-sloth/c20e-sloth.plymouth"
 printf '%s\n' 'img = Image("sloth.png");' 'sprite = Sprite(img);' 'sprite.SetX(Window.GetWidth()/2-img.GetWidth()/2);' 'sprite.SetY(Window.GetHeight()/2-img.GetHeight()/2);' >"$ROOT/usr/share/plymouth/themes/c20e-sloth/c20e-sloth.script"
 chroot "$ROOT" plymouth-set-default-theme c20e-sloth 2>/dev/null || true
fi
note "6/9 - Install first-boot account provisioning"
install -d "$ROOT/usr/local/sbin" "$ROOT/var/lib/c20e"
cat >"$ROOT/usr/local/sbin/c20e-firstboot" <<'EOF'
#!/bin/bash
set -e
MARK=/var/lib/c20e/firstboot-complete
[ -e "$MARK" ] && exit 0
clear
echo "Aiprotablet C20e - First Boot Setup"
echo
while :; do
 read -r -p "Create username: " U
 case "$U" in ""|root|chaos|*[!a-z0-9_-]*) echo "Use lowercase letters, numbers, _ or -; not root/chaos.";; *) id "$U" >/dev/null 2>&1 && echo "Account exists." || break;; esac
done
read -r -p "Hostname [c20e]: " H
H="${H:-c20e}"
useradd -m -s /bin/bash "$U"
while ! passwd "$U"; do echo "Try password again."; done
for G in sudo adm audio video render input plugdev netdev dialout; do getent group "$G" >/dev/null && usermod -aG "$G" "$U"; done
echo "$H" >/etc/hostname
hostnamectl set-hostname "$H" 2>/dev/null || true
if id chaos >/dev/null 2>&1; then passwd -l chaos >/dev/null 2>&1 || true; usermod -L chaos >/dev/null 2>&1 || true; fi
rm -f /etc/lightdm/lightdm.conf.d/*autologin* 2>/dev/null || true
touch "$MARK"
systemctl disable c20e-firstboot.service >/dev/null 2>&1 || true
systemctl set-default graphical.target
systemctl enable lightdm.service >/dev/null 2>&1 || true
echo "Setup complete. Rebooting..."
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
systemctl --root="$ROOT" enable c20e-firstboot.service >/dev/null
systemctl --root="$ROOT" set-default multi-user.target >/dev/null
systemctl --root="$ROOT" disable lightdm.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable c20e-usb-debug.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" enable serial-getty@ttyGS0.service >/dev/null 2>&1 || true
systemctl --root="$ROOT" disable usb-role-manager.service >/dev/null 2>&1 || true
note "7/9 - Deploy built kernel/DTB to SD rootfs"
cp -a "$ROOT/boot/Image" "$REPORT/backups/rootfs-Image" 2>/dev/null || true
cp -a "$ROOT/boot/rk3562.dtb" "$REPORT/backups/rootfs-rk3562.dtb" 2>/dev/null || true
install -m 0644 "$K/arch/arm64/boot/Image" "$ROOT/boot/Image"
install -m 0644 "$DTB" "$ROOT/boot/rk3562.dtb"
sync
cmp "$K/arch/arm64/boot/Image" "$ROOT/boot/Image"
cmp "$DTB" "$ROOT/boot/rk3562.dtb"
note "8/9 - Validation"
sha256sum "$K/arch/arm64/boot/Image" "$DTB" "$ROOT/boot/Image" "$ROOT/boot/rk3562.dtb" >"$REPORT/sha256.txt"
systemctl --root="$ROOT" get-default >"$REPORT/default-target.txt"
systemctl --root="$ROOT" is-enabled c20e-firstboot.service >"$REPORT/firstboot.txt" 2>&1 || true
systemctl --root="$ROOT" is-enabled c20e-usb-debug.service >"$REPORT/usb-debug.txt" 2>&1 || true
git -C "$K" status --short >"$REPORT/kernel-status.txt" 2>&1 || true
note "9/9 - Package report"
tar -C "$REPO" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
echo
echo "SUCCESS: integration build/deployment completed."
echo "Report: $REPORT.tar.gz"
echo "Full log: $RUNLOG"
echo "First boot target: $(systemctl --root="$ROOT" get-default)"
echo "USB recovery console remains enabled."
if [ -f "$REPORT/GC02M1-BLOCKER.txt" ]; then echo "KNOWN LIMITATION: front GC02M1 cannot bind until a real Linux GC02M1 sensor driver is available/ported."; fi
echo "Internal eMMC was not touched."
