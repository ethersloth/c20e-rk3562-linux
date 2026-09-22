#!/usr/bin/env bash
# Pin DDR frequency (and optionally the CPU) on a C20e card, without a rebuild.
#
# Why: the corruption only appears once the graphical session runs. Captured
# boots to multi-user.target produced 0 oopses; the boots to graphical.target
# produced 4, 7 and 2 plus panics. slub_debug=FZPU was active for the last one
# and reported NOTHING, while the faults included an SP/PC alignment exception,
# a jump to address 0x1, and oopses in the idle task (swapper). That pattern is
# below the allocator: it is not a software use-after-free.
#
# The likely mechanism is in the boot log:
#
#   rockchip-vop2 ff400000.vop: failed to init opp info
#   rockchip-dmc dmc: failed to get vop bandwidth to dmc rate
#   rockchip-dmc dmc: failed to get vop pn to msch rl
#
# The DDR devfreq governor is scaling DRAM while unable to read what the VOP2
# scanout needs. DDR frequency transitions under display load are a plausible
# source of real memory errors, which would corrupt anything -- kernel stacks,
# per-CPU scheduler state, saved registers -- exactly as observed.
#
# This pins the DDR devfreq governor to performance (highest frequency, no
# transitions). If the oopses stop, DMC DVFS is confirmed and the permanent
# fix belongs in the board DTS (&dmc status, or fixing the VOP bandwidth
# properties it is failing to read).
#
# --cpu also moves the CPU off the `performance` governor, which build.sh
# defaults to and which pins the top OPP (2016MHz at 1.125V for this L2-binned
# part) one hundred percent of the time. Leave it off for the first run so only
# one variable changes.
#
# Usage: sudo ./apply-c20e-dvfs-policy.sh [/dev/sdX] [--cpu] [--remove]
set -Eeuo pipefail

DEV="/dev/sda"; DO_CPU=0; REMOVE=0
for a in "$@"; do
    case "$a" in
        --cpu)    DO_CPU=1 ;;
        --remove) REMOVE=1 ;;
        /dev/*)   DEV="$a" ;;
        *) echo "ERROR: unknown argument $a" >&2; exit 1 ;;
    esac
done

MNT="$(mktemp -d)"
die(){ echo "ERROR: $*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -b "${DEV}4" ]] || die "no ${DEV}4 -- is the card in and is $DEV right?"
[[ "$(lsblk -dnro TRAN "$DEV" 2>/dev/null)" == "usb" ]] || die "$DEV is not reported as USB."

mount "${DEV}4" "$MNT" || die "could not mount ${DEV}4"
[[ -d "$MNT/etc/systemd/system" ]] || die "${DEV}4 does not look like the rootfs"

if [[ "$REMOVE" -eq 1 ]]; then
    rm -f "$MNT/etc/systemd/system/c20e-dvfs-policy.service" \
          "$MNT/etc/systemd/system/multi-user.target.wants/c20e-dvfs-policy.service" \
          "$MNT/usr/local/sbin/c20e-dvfs-policy"
    sync; echo "[+] removed the DVFS policy"; exit 0
fi

cat > "$MNT/usr/local/sbin/c20e-dvfs-policy" <<POLICY
#!/bin/bash
# Pin DDR frequency. See apply-c20e-dvfs-policy.sh for the reasoning.
LOG=/var/log/c20e-dvfs-policy.log
exec >>"\$LOG" 2>&1
echo "=== c20e dvfs policy \$(date -Is) ==="

for d in /sys/class/devfreq/*dmc* /sys/class/devfreq/dmc; do
    [ -d "\$d" ] || continue
    echo "device: \$d"
    echo "  available: \$(cat "\$d/available_governors" 2>/dev/null)"
    echo "  before:    \$(cat "\$d/governor" 2>/dev/null) @ \$(cat "\$d/cur_freq" 2>/dev/null)"
    if echo performance > "\$d/governor" 2>/dev/null; then
        echo "  after:     \$(cat "\$d/governor" 2>/dev/null) @ \$(cat "\$d/cur_freq" 2>/dev/null)"
    else
        echo "  FAILED to set governor"
    fi
done

if [ "${DO_CPU}" = "1" ]; then
    for c in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "\$c" ] || continue
        for g in schedutil ondemand conservative; do
            if grep -qw "\$g" "\$c/scaling_available_governors" 2>/dev/null; then
                echo "\$g" > "\$c/scaling_governor" 2>/dev/null && break
            fi
        done
    done
    echo "cpu governor now: \$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    echo "cpu cur freq:     \$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
fi
exit 0
POLICY
chmod 0755 "$MNT/usr/local/sbin/c20e-dvfs-policy"

cat > "$MNT/etc/systemd/system/c20e-dvfs-policy.service" <<'UNIT'
[Unit]
Description=C20e DVFS policy (pin DDR frequency)
# Must win over anything that sets a governor later, and must be in place
# before the display starts driving DDR bandwidth.
After=sysinit.target
Before=display-manager.service lightdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/c20e-dvfs-policy
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/c20e-dvfs-policy.service \
       "$MNT/etc/systemd/system/multi-user.target.wants/c20e-dvfs-policy.service"

sync
echo "[+] installed c20e-dvfs-policy.service (DDR pinned to performance)"
[[ "$DO_CPU" -eq 1 ]] && echo "[+] CPU governor will also be moved off 'performance'"
echo
echo "SUCCESS - put the card in the tablet and boot to the desktop."
echo "Let it sit a few minutes. Then collect logs:"
echo "  sudo ./collect-c20e-logs.sh $DEV"
echo "and check /var/log/c20e-dvfs-policy.log in the capture to confirm it applied."
