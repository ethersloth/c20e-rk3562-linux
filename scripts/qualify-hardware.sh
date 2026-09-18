#!/usr/bin/env bash
set -uo pipefail

OUTPUT="${1:-}"
BOOT_PARTUUID='f2e4c648-207d-45f0-b5ad-7886f75e57eb'
COMMAND_TIMEOUT="${C20E_QUALIFY_TIMEOUT:-15}"
ACTIVE_TESTS="${C20E_QUALIFY_ACTIVE_TESTS:-0}"

# Keep progress visible on the invoking terminal even when report output is piped.
exec 3>&2

if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    exec > >(tee "$OUTPUT") 2>&1
fi

progress() {
    printf '[%(%H:%M:%S)T] %-7s %s\n' -1 "$1" "$2" >&3
}

section() {
    progress SECTION "$1"
    printf '\n===== %s =====\n' "$1"
}

run() {
    local description="$1"
    local started=$SECONDS
    shift
    progress START "$description"
    printf '\n--- %s ---\n' "$description"
    if command -v "$1" >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout --kill-after=2s "${COMMAND_TIMEOUT}s" "$@" </dev/null 2>&1
        else
            "$@" </dev/null 2>&1
        fi
        local command_status=$?
        if (( command_status == 124 || command_status == 137 )); then
            progress TIMEOUT "$description ($((SECONDS - started))s)"
            printf '[WARN] command timed out after %s seconds\n' "$COMMAND_TIMEOUT"
        elif (( command_status != 0 )); then
            progress FAILED "$description (exit $command_status, $((SECONDS - started))s)"
            printf '[WARN] command exited %d\n' "$command_status"
        else
            progress DONE "$description ($((SECONDS - started))s)"
        fi
    else
        progress SKIP "$description (command not installed: $1)"
        printf '[SKIP] command not installed: %s\n' "$1"
    fi
}

active_run() {
    if [[ "$ACTIVE_TESTS" == 1 ]]; then
        run "$@"
    else
        progress SKIP "$1 (active probe disabled)"
        printf '\n--- %s ---\n' "$1"
        printf '[SKIP] active probe disabled; set C20E_QUALIFY_ACTIVE_TESTS=1 to run\n'
    fi
}

show_glob() {
    local path
    local found=0
    for path in $1; do
        [[ -e "$path" ]] || continue
        found=1
        progress INSPECT "$path"
        printf '\n--- %s ---\n' "$path"
        if [[ -d "$path" ]]; then
            find "$path" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort
        elif [[ -f "$path" ]]; then
            cat "$path" 2>/dev/null || printf '[WARN] unable to read %s\n' "$path"
        else
            ls -l "$path" 2>/dev/null || printf '[WARN] unable to inspect %s\n' "$path"
        fi
        progress DONE "$path"
    done
    if (( ! found )); then
        progress NONE "$1"
        printf '[NONE] %s\n' "$1"
    fi
}

show_active_boot() {
    local device="/dev/disk/by-partuuid/$BOOT_PARTUUID"
    local mountpoint_path

    progress START "Active boot filesystem inspection"
    if [[ ! -e "$device" ]]; then
        progress FAILED "Active boot filesystem (PARTUUID not present)"
        printf '[WARN] boot PARTUUID %s is not present\n' "$BOOT_PARTUUID"
        return
    fi
    mountpoint_path="$(findmnt -nr -S "$(readlink -f "$device")" -o TARGET 2>/dev/null | head -n 1)"
    if [[ -z "$mountpoint_path" ]]; then
        progress FAILED "Active boot filesystem (not mounted)"
        printf '[WARN] active boot partition %s is not mounted; hashes unavailable\n' "$device"
        return
    fi

    printf 'Boot device: %s\nMountpoint: %s\n' "$(readlink -f "$device")" "$mountpoint_path"
    sha256sum "$mountpoint_path/Image" "$mountpoint_path/rk3562.dtb" 2>&1 || true
    printf '\n--- extlinux.conf ---\n'
    cat "$mountpoint_path/extlinux/extlinux.conf" 2>&1 || true
    progress DONE "Active boot filesystem inspection"
}

printf 'C20e RK3562 hardware qualification report\n'
printf 'Generated: %s\n' "$(date -Is)"
printf 'Hostname:  %s\n' "$(hostname 2>/dev/null || printf unknown)"
printf 'User:      %s (uid %s)\n' "$(id -un)" "$(id -u)"
printf 'Mode:      read-only inspection; active tests=%s; suspend is not triggered\n' "$ACTIVE_TESTS"

section 'Kernel and boot artifacts'
run 'Kernel' uname -a
run 'Kernel command line' cat /proc/cmdline
run 'OS release' cat /etc/os-release
printf '\n--- Active boot filesystem by PARTUUID ---\n'
show_active_boot
run 'Filesystem mounts' findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS

section 'Kernel modules and firmware'
run 'Seekwave modules loaded' sh -c "lsmod | grep -E '^(skw|swt)' || true"
run 'skw module metadata' modinfo skw
run 'skw_sdio_lite module metadata' modinfo skw_sdio_lite
run 'Running modules.builtin hash' sha256sum "/lib/modules/$(uname -r)/modules.builtin"
run 'Seekwave firmware hashes' sh -c "find /lib/firmware/seekwave -maxdepth 1 -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum"
run 'Regulatory database files' sh -c 'ls -l /lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s 2>&1; find /lib/firmware -maxdepth 2 \( -type f -o -type l \) -name "regulatory.db*" -print 2>/dev/null | sort'

section 'Wi-Fi and networking'
run 'NetworkManager device state' nmcli device status
run 'NetworkManager general state' nmcli general status
run 'IP addresses' ip -brief address
run 'Routes' ip route
run 'Wi-Fi link' iw dev wlan0 link
run 'Wireless PHYs' iw dev
run 'RF kill switches' rfkill list
run 'DNS state' resolvectl status
run 'NetworkManager service' systemctl --no-pager --full status NetworkManager.service

section 'Touch and input'
run 'Input device summary' sh -c "grep -E '^(N: Name|H: Handlers|B: ABS)' /proc/bus/input/devices"
run 'libinput devices' libinput list-devices
show_glob '/dev/input/event*'

section 'Battery and charging'
show_glob '/sys/class/power_supply/*'
run 'Power-supply properties' sh -c 'for supply in /sys/class/power_supply/*; do [ -d "$supply" ] || continue; echo "--- $supply ---"; for key in type status present online capacity voltage_now current_now charge_now charge_full energy_now energy_full; do if [ -r "$supply/$key" ]; then printf "%s=" "$key"; cat "$supply/$key"; fi; done; done'
run 'UPower devices' upower -e
run 'UPower battery detail' sh -c 'for device in $(upower -e 2>/dev/null | grep -E "battery|DisplayDevice"); do upower -i "$device"; done'

section 'Audio'
run 'ALSA cards' cat /proc/asound/cards
run 'Playback devices' aplay -l
run 'Capture devices' arecord -l
run 'PipeWire sinks and sources' wpctl status

section 'Bluetooth'
run 'Bluetooth controllers' bluetoothctl list
run 'Bluetooth controller details' bluetoothctl show
run 'Bluetooth service' systemctl --no-pager --full status bluetooth.service
run 'Bluetooth interfaces' hciconfig -a

section 'Display and GPU'
show_glob '/dev/dri/*'
run 'DRM connectors and modes' sh -c 'for node in /sys/class/drm/card*-*/status /sys/class/drm/card*-*/modes; do [ -r "$node" ] && echo "--- $node ---" && cat "$node"; done'
active_run 'OpenGL renderer' glxinfo -B
active_run 'EGL renderer' eglinfo -B

section 'USB-C and USB devices'
run 'USB device tree' lsusb -t
run 'USB devices' lsusb
show_glob '/sys/class/typec/*'
run 'USB role switches' sh -c 'for role in /sys/class/usb_role/*/role; do [ -r "$role" ] && printf "%s: " "$role" && cat "$role"; done'
run 'USB gadget configuration' sh -c 'find /sys/kernel/config/usb_gadget -maxdepth 3 -type f -readable -print 2>/dev/null | sort'

section 'Cameras and media graph'
show_glob '/dev/video*'
show_glob '/dev/media*'
run 'Media controller topology' sh -c 'for media in /dev/media*; do [ -e "$media" ] && media-ctl -d "$media" -p; done'
run 'V4L2 devices' v4l2-ctl --list-devices

section 'Suspend support'
show_glob '/sys/power/state'
show_glob '/sys/power/mem_sleep'
run 'Logind power-key and lid state' loginctl show-seat seat0
printf '\n[INFO] This report does not suspend the tablet. Perform the timed wake test manually.\n'

section 'Services and boot health'
run 'Failed systemd units' systemctl --failed --no-pager --full
run 'Power-profile ordering diagnostics' systemctl --no-pager --full status rk-power-profile-sync.service power-profiles-daemon.service
run 'Kernel warnings and errors this boot' journalctl -b -k -p warning..alert --no-pager
run 'Release-relevant kernel messages' sh -c "dmesg | grep -Eai 'oops|panic|BUG:|unable to handle|segfault|hung task|lockup|seekwave|skw|sv6160|regulatory.db|gsl|touch|rk817|charger|battery|suspend|wakeup|alsa|audio|bluetooth|hci|panfrost|drm|typec|husb320|dwc3|ov5648|dw9714|gc02m1|rknpu|autofs4|ordering cycle' | tail -n 500"

section 'Manual qualification still required'
cat <<'CHECKLIST'
[ ] touchscreen full-panel, rotation, multi-touch, and post-resume
[ ] battery charge/discharge and USB power-source transitions
[ ] suspend several minutes; wake display, touch, Wi-Fi, and audio
[ ] speaker, microphone, and headphone paths
[ ] Bluetooth scan, pair, connect, and reconnect
[ ] GPU renderer is Panfrost hardware, not software fallback
[ ] USB-C device mode, host mode, storage, and keyboard
[ ] rear/front camera and autofocus status documented
[ ] several-hour stability run with Wi-Fi traffic and charging
CHECKLIST

progress COMPLETE 'Hardware qualification report'
printf '\nReport complete. Review [WARN], [SKIP], [NONE], and manual checks above.\n'