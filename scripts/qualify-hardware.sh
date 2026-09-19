#!/usr/bin/env bash

#
# C20e RK3562 Hardware Qualification Script
#
# Purpose:
#   Collect read-only hardware, kernel, driver, networking, power,
#   audio, Bluetooth, display, USB, camera, and system-health
#   information from the C20e Debian ARM64 tablet.
#
# Usage:
#
#   sudo ./c20e-qualify.sh
#
#   or write the detailed report to a file while showing progress
#   on the terminal:
#
#   sudo ./c20e-qualify.sh ./c20e-qualification.txt
#
# Optional environment variables:
#
#   C20E_QUALIFY_TIMEOUT=30
#       Change the per-command timeout from the default 15 seconds.
#
#   C20E_QUALIFY_ACTIVE_TESTS=1
#       Enable active graphics probes such as glxinfo and eglinfo.
#
# Example:
#
#   sudo C20E_QUALIFY_ACTIVE_TESTS=1 \
#       ./c20e-qualify.sh ./c20e-qualification.txt
#

set -uo pipefail


###############################################################################
# Configuration
###############################################################################

OUTPUT="${1:-}"

BOOT_PARTUUID='f2e4c648-207d-45f0-b5ad-7886f75e57eb'

COMMAND_TIMEOUT="${C20E_QUALIFY_TIMEOUT:-15}"

ACTIVE_TESTS="${C20E_QUALIFY_ACTIVE_TESTS:-0}"

SCRIPT_START_SECONDS=$SECONDS

STEP_NUMBER=0
CURRENT_STEP=0


###############################################################################
# Progress output
#
# File descriptor 3 is reserved exclusively for live terminal progress.
#
# We explicitly open /dev/tty when possible so progress remains visible even
# after stdout and stderr are redirected into the qualification report.
###############################################################################

if exec 3>/dev/tty 2>/dev/null; then
    :
else
    exec 3>&2
fi


###############################################################################
# Utility functions
###############################################################################

timestamp() {
    date '+%H:%M:%S'
}


elapsed() {
    local seconds="${1:-0}"

    printf '%02d:%02d:%02d' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}


progress() {
    local status="$1"
    local message="$2"

    printf '[%s] %-8s %s\n' \
        "$(timestamp)" \
        "$status" \
        "$message" >&3
}


section() {
    local title="$1"

    progress "SECTION" "$title"

    printf '\n'
    printf '===============================================================================\n'
    printf '%s\n' "$title"
    printf '===============================================================================\n'
}


start_step() {
    local description="$1"
    local step_label

    STEP_NUMBER=$((STEP_NUMBER + 1))
    CURRENT_STEP=$STEP_NUMBER

    printf -v step_label '%03d' "$CURRENT_STEP"

    progress "START" "[$step_label] $description"
}


step_status() {
    local status="$1"
    local description="$2"
    local duration="${3:-}"
    local step_label

    printf -v step_label '%03d' "$CURRENT_STEP"

    if [[ -n "$duration" ]]; then
        progress "$status" "[$step_label] $description ($duration)"
    else
        progress "$status" "[$step_label] $description"
    fi
}


skip_step() {
    local description="$1"
    local reason="$2"

    start_step "$description"
    step_status "SKIP" "$description - $reason"

    printf '\n--- %s ---\n' "$description"
    printf '[SKIP] %s\n' "$reason"
}


command_exists() {
    command -v "$1" >/dev/null 2>&1
}


###############################################################################
# Command runner
#
# Runs a command with:
#   - terminal progress
#   - detailed output in the report
#   - timeout protection
#   - non-fatal failure handling
###############################################################################

run() {
    local description="$1"
    local started
    local command_status
    local duration
    local executable

    shift

    executable="${1:-}"

    start_step "$description"
    started=$SECONDS

    printf '\n--- %s ---\n' "$description"

    if [[ -z "$executable" ]]; then
        step_status "FAILED" "$description" "invalid command"

        printf '[WARN] No command was supplied.\n'

        return 0
    fi

    if ! command_exists "$executable"; then
        duration="$(elapsed $((SECONDS - started)))"

        step_status \
            "SKIP" \
            "$description - command not installed: $executable" \
            "$duration"

        printf '[SKIP] command not installed: %s\n' "$executable"

        return 0
    fi

    command_status=0

    if command_exists timeout; then

        timeout \
            --kill-after=2s \
            "${COMMAND_TIMEOUT}s" \
            "$@" \
            </dev/null \
            2>&1

        command_status=$?

    else

        "$@" </dev/null 2>&1
        command_status=$?

    fi

    duration="$(elapsed $((SECONDS - started)))"

    case "$command_status" in

        0)
            step_status "DONE" "$description" "$duration"
            ;;

        124|137)
            step_status "TIMEOUT" "$description" "$duration"

            printf \
                '[WARN] command timed out after %s seconds\n' \
                "$COMMAND_TIMEOUT"
            ;;

        *)
            step_status \
                "FAILED" \
                "$description - exit $command_status" \
                "$duration"

            printf \
                '[WARN] command exited with status %d\n' \
                "$command_status"
            ;;

    esac

    #
    # A failed qualification check must not terminate the entire report.
    #
    return 0
}


###############################################################################
# Active command runner
#
# Potentially active probes remain disabled unless explicitly requested.
###############################################################################

active_run() {
    local description="$1"

    if [[ "$ACTIVE_TESTS" == "1" ]]; then

        run "$@"

    else

        start_step "$description"

        step_status \
            "SKIP" \
            "$description - active probe disabled"

        printf '\n--- %s ---\n' "$description"

        printf '%s\n' \
            '[SKIP] active probe disabled.'

        printf '%s\n' \
            '[INFO] Set C20E_QUALIFY_ACTIVE_TESTS=1 to enable active probes.'

    fi
}


###############################################################################
# Glob/path inspector
###############################################################################

show_glob() {
    local pattern="$1"
    local description="${2:-$1}"

    local -a paths=()
    local path

    start_step "$description"

    #
    # compgen safely expands shell glob patterns without leaving the literal
    # pattern behind when nothing matches.
    #
    while IFS= read -r path; do
        paths+=("$path")
    done < <(compgen -G "$pattern" | sort)

    if (( ${#paths[@]} == 0 )); then

        step_status "NONE" "$description"

        printf '\n--- %s ---\n' "$description"
        printf '[NONE] No entries matched: %s\n' "$pattern"

        return 0
    fi

    for path in "${paths[@]}"; do

        printf '\n--- %s ---\n' "$path"

        #
        # Device nodes
        #
        if [[ -b "$path" || -c "$path" ]]; then

            ls -l "$path" 2>&1 || \
                printf '[WARN] unable to inspect %s\n' "$path"

        #
        # Directories or symlinks resolving to directories
        #
        elif [[ -d "$path" ]]; then

            ls -ld "$path" 2>&1 || true

            find -L "$path" \
                -maxdepth 1 \
                -mindepth 1 \
                -printf '%f\n' \
                2>/dev/null \
                | sort

        #
        # Ordinary readable files
        #
        elif [[ -f "$path" ]]; then

            if [[ -r "$path" ]]; then
                cat "$path" 2>/dev/null || \
                    printf '[WARN] unable to read %s\n' "$path"
            else
                ls -l "$path" 2>&1 || true
                printf '[WARN] file is not readable: %s\n' "$path"
            fi

        #
        # Anything else
        #
        else

            ls -l "$path" 2>&1 || \
                printf '[WARN] unable to inspect %s\n' "$path"

        fi

    done

    step_status \
        "DONE" \
        "$description - ${#paths[@]} item(s)"
}


###############################################################################
# Active boot filesystem inspection
###############################################################################

show_active_boot() {
    local device="/dev/disk/by-partuuid/$BOOT_PARTUUID"

    local resolved_device
    local mountpoint_path
    local artifact

    start_step "Active boot filesystem inspection"

    printf '\n--- Active boot filesystem ---\n'

    if [[ ! -e "$device" ]]; then

        step_status \
            "FAILED" \
            "Active boot filesystem - PARTUUID not present"

        printf \
            '[WARN] boot PARTUUID %s is not present\n' \
            "$BOOT_PARTUUID"

        return 0
    fi

    resolved_device="$(readlink -f "$device" 2>/dev/null || true)"

    if [[ -z "$resolved_device" ]]; then

        step_status \
            "FAILED" \
            "Active boot filesystem - unable to resolve device"

        printf \
            '[WARN] unable to resolve %s\n' \
            "$device"

        return 0
    fi

    if ! command_exists findmnt; then

        step_status \
            "SKIP" \
            "Active boot filesystem - findmnt unavailable"

        printf '[SKIP] findmnt is not installed\n'

        return 0
    fi

    mountpoint_path="$(
        findmnt \
            -nr \
            -S "$resolved_device" \
            -o TARGET \
            2>/dev/null \
            | head -n 1
    )"

    if [[ -z "$mountpoint_path" ]]; then

        step_status \
            "FAILED" \
            "Active boot filesystem - partition is not mounted"

        printf \
            '[WARN] active boot partition %s is not mounted\n' \
            "$resolved_device"

        return 0
    fi

    printf 'Boot PARTUUID: %s\n' "$BOOT_PARTUUID"
    printf 'Boot device:   %s\n' "$resolved_device"
    printf 'Mountpoint:    %s\n' "$mountpoint_path"

    printf '\n--- Boot artifact hashes ---\n'

    for artifact in \
        "$mountpoint_path/Image" \
        "$mountpoint_path/rk3562.dtb"
    do

        if [[ -f "$artifact" ]]; then

            sha256sum "$artifact" 2>&1 || true

        else

            printf \
                '[WARN] boot artifact not found: %s\n' \
                "$artifact"

        fi

    done

    printf '\n--- extlinux.conf ---\n'

    if [[ -r "$mountpoint_path/extlinux/extlinux.conf" ]]; then

        cat "$mountpoint_path/extlinux/extlinux.conf"

    else

        printf \
            '[WARN] extlinux.conf not found or unreadable: %s\n' \
            "$mountpoint_path/extlinux/extlinux.conf"

    fi

    step_status \
        "DONE" \
        "Active boot filesystem inspection"
}


###############################################################################
# Interrupt handling
###############################################################################

handle_interrupt() {
    printf '\n' >&3

    progress \
        "ABORT" \
        "Qualification interrupted by user."

    printf '\n[ABORT] Qualification interrupted.\n'

    exit 130
}


trap handle_interrupt INT TERM


###############################################################################
# Initial progress
###############################################################################

progress \
    "START" \
    "Starting C20e hardware qualification"

if [[ -n "$OUTPUT" ]]; then

    mkdir -p "$(dirname "$OUTPUT")"

    #
    # From this point onward stdout and stderr go into the detailed report.
    # FD 3 remains connected to the user's terminal.
    #
    exec >"$OUTPUT" 2>&1

    progress \
        "REPORT" \
        "Detailed output: $OUTPUT"

else

    progress \
        "REPORT" \
        "No report filename supplied; detailed output will remain on terminal"

fi


###############################################################################
# Report header
###############################################################################

printf 'C20e RK3562 hardware qualification report\n'
printf '==========================================\n\n'

printf 'Generated:     %s\n' "$(date -Is)"
printf 'Hostname:      %s\n' "$(hostname 2>/dev/null || printf unknown)"
printf 'User:          %s\n' "$(id -un 2>/dev/null || printf unknown)"
printf 'UID:           %s\n' "$(id -u 2>/dev/null || printf unknown)"
printf 'Kernel:        %s\n' "$(uname -r 2>/dev/null || printf unknown)"
printf 'Architecture:  %s\n' "$(uname -m 2>/dev/null || printf unknown)"
printf 'Command limit: %s seconds\n' "$COMMAND_TIMEOUT"
printf 'Active tests:  %s\n' "$ACTIVE_TESTS"

printf '\n'

if [[ "$(id -u 2>/dev/null || printf 1)" != "0" ]]; then

    printf '%s\n' \
        '[WARN] Script is not running as root.'

    printf '%s\n' \
        '[WARN] Some journal, kernel, device, and sysfs information may be unavailable.'

    progress \
        "WARN" \
        "Not running as root; some checks may have limited access"

else

    printf '%s\n' \
        '[INFO] Script is running with root privileges.'

fi

printf '\n'
printf '%s\n' \
    'Mode: read-only inspection; the script does not intentionally suspend the tablet.'


###############################################################################
# Kernel and boot artifacts
###############################################################################

section 'Kernel and boot artifacts'

run \
    'Kernel identification' \
    uname -a

run \
    'Kernel command line' \
    cat /proc/cmdline

run \
    'Operating system release' \
    cat /etc/os-release

show_active_boot

run \
    'Filesystem mounts' \
    findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS


###############################################################################
# Kernel modules and firmware
###############################################################################

section 'Kernel modules and firmware'

run \
    'Seekwave modules loaded' \
    sh -c \
    "lsmod | grep -E '^(skw|swt)' || true"

run \
    'skw module metadata' \
    modinfo skw

run \
    'skw_sdio_lite module metadata' \
    modinfo skw_sdio_lite

run \
    'Running modules.builtin hash' \
    sha256sum "/lib/modules/$(uname -r)/modules.builtin"

run \
    'Seekwave firmware hashes' \
    sh -c \
    'find /lib/firmware/seekwave \
        -maxdepth 1 \
        -type f \
        -print0 2>/dev/null \
     | sort -z \
     | xargs -0 -r sha256sum'

run \
    'Regulatory database files' \
    sh -c \
    'ls -l \
        /lib/firmware/regulatory.db \
        /lib/firmware/regulatory.db.p7s \
        2>&1

     printf "\nDiscovered regulatory database files:\n"

     find /lib/firmware \
        -maxdepth 2 \
        \( -type f -o -type l \) \
        -name "regulatory.db*" \
        -print \
        2>/dev/null \
        | sort'


###############################################################################
# Wi-Fi and networking
###############################################################################

section 'Wi-Fi and networking'

run \
    'NetworkManager device state' \
    nmcli device status

run \
    'NetworkManager general state' \
    nmcli general status

run \
    'IP addresses' \
    ip -brief address

run \
    'Routes' \
    ip route

run \
    'Wi-Fi link' \
    iw dev wlan0 link

run \
    'Wireless PHYs and interfaces' \
    iw dev

run \
    'RF kill switches' \
    rfkill list

run \
    'DNS state' \
    resolvectl status

run \
    'NetworkManager service' \
    systemctl \
        --no-pager \
        --full \
        status \
        NetworkManager.service


###############################################################################
# Touch and input
###############################################################################

section 'Touch and input'

run \
    'Input device summary' \
    sh -c \
    "grep -E '^(N: Name|H: Handlers|B: ABS)' \
        /proc/bus/input/devices"

run \
    'libinput devices' \
    libinput list-devices

show_glob \
    '/dev/input/event*' \
    'Input event device nodes'


###############################################################################
# Battery and charging
###############################################################################

section 'Battery and charging'

show_glob \
    '/sys/class/power_supply/*' \
    'Power-supply sysfs devices'

run \
    'Power-supply properties' \
    sh -c \
    '
    found=0

    for supply in /sys/class/power_supply/*; do

        [ -d "$supply" ] || continue

        found=1

        echo
        echo "--- $supply ---"

        for key in \
            type \
            status \
            present \
            online \
            capacity \
            voltage_now \
            current_now \
            charge_now \
            charge_full \
            charge_full_design \
            energy_now \
            energy_full \
            energy_full_design \
            power_now \
            temp
        do

            if [ -r "$supply/$key" ]; then

                printf "%s=" "$key"
                cat "$supply/$key"

            fi

        done

    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No power-supply devices found."
    fi
    '

run \
    'UPower devices' \
    upower -e

run \
    'UPower battery detail' \
    sh -c \
    '
    if ! command -v upower >/dev/null 2>&1; then
        exit 127
    fi

    found=0

    for device in $(upower -e 2>/dev/null | grep -E "battery|DisplayDevice"); do

        found=1

        echo
        echo "--- $device ---"

        upower -i "$device"

    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No battery or DisplayDevice entries reported by UPower."
    fi
    '

run \
    'Kernel and UPower battery-state consistency' \
    sh -c \
    '
    kernel_state="$(cat /sys/class/power_supply/battery/status 2>/dev/null || true)"
    upower_device="$(upower -e 2>/dev/null | grep "/battery_" | head -n 1)"
    upower_state=""

    if [ -n "$upower_device" ]; then
        upower_state="$(upower -i "$upower_device" 2>/dev/null | awk "/^[[:space:]]*state:/ { print \$2; exit }")"
    fi

    printf "Kernel battery state: %s\n" "${kernel_state:-unknown}"
    printf "UPower battery state: %s\n" "${upower_state:-unknown}"

    kernel_normalized="$(printf "%s" "$kernel_state" | tr "[:upper:]" "[:lower:]")"
    if [ -n "$kernel_normalized" ] && [ -n "$upower_state" ] && [ "$kernel_normalized" != "$upower_state" ]; then
        echo "[WARN] Kernel and UPower battery states disagree."
        exit 1
    fi
    '


###############################################################################
# Audio
###############################################################################

section 'Audio'

run \
    'ALSA cards' \
    cat /proc/asound/cards

run \
    'Playback devices' \
    aplay -l

run \
    'Capture devices' \
    arecord -l

run \
    'PipeWire sinks and sources' \
    wpctl status


###############################################################################
# Bluetooth
###############################################################################

section 'Bluetooth'

run \
    'skwbt module metadata' \
    modinfo skwbt

show_glob \
    '/sys/class/bluetooth/*' \
    'Bluetooth HCI sysfs devices'

show_glob \
    '/sys/bus/platform/devices/btseekwave*' \
    'Seekwave Bluetooth platform devices'

run \
    'Bluetooth service' \
    systemctl \
        --no-pager \
        --full \
        status \
        bluetooth.service

if systemctl is-active --quiet bluetooth.service 2>/dev/null; then
    run \
        'Bluetooth controllers' \
        bluetoothctl list

    run \
        'Bluetooth controller details' \
        bluetoothctl show
else
    skip_step \
        'Bluetooth controllers' \
        'bluetooth.service is not active'

    skip_step \
        'Bluetooth controller details' \
        'bluetooth.service is not active'
fi

run \
    'Bluetooth interfaces' \
    hciconfig -a


###############################################################################
# Display and GPU
###############################################################################

section 'Display and GPU'

show_glob \
    '/dev/dri/*' \
    'DRM device nodes'

run \
    'DRM connectors and modes' \
    sh -c \
    '
    found=0

    for node in \
        /sys/class/drm/card*-*/status \
        /sys/class/drm/card*-*/modes
    do

        [ -r "$node" ] || continue

        found=1

        echo
        echo "--- $node ---"

        cat "$node"

    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No readable DRM connector status/mode files found."
    fi
    '

active_run \
    'OpenGL renderer' \
    glxinfo -B

active_run \
    'EGL renderer' \
    eglinfo -B


###############################################################################
# USB-C and USB
###############################################################################

section 'USB-C and USB devices'

run \
    'USB device tree' \
    lsusb -t

run \
    'USB devices' \
    lsusb

show_glob \
    '/sys/class/typec/*' \
    'USB Type-C sysfs devices'

run \
    'USB Type-C port state' \
    sh -c \
    '
    found=0

    for port in /sys/class/typec/port*; do
        [ -d "$port" ] || continue
        case "$(basename "$port")" in
            *-partner) continue ;;
        esac

        found=1
        echo "--- $port ---"
        for key in data_role power_role port_type preferred_role orientation power_operation_mode; do
            if [ -r "$port/$key" ]; then
                value="$(cat "$port/$key" 2>/dev/null || true)"
                printf "%s=%s\n" "$key" "$value"
            fi
        done
    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No USB Type-C ports found."
    fi
    '

run \
    'USB role switches' \
    sh -c \
    '
    found=0

    for role in /sys/class/usb_role/*/role; do

        [ -r "$role" ] || continue

        found=1

        printf "%s: " "$role"
        cat "$role"

    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No USB role-switch interfaces found."
    fi
    '

run \
    'USB gadget configuration' \
    sh -c \
    '
    if [ ! -d /sys/kernel/config/usb_gadget ]; then
        echo "[NONE] /sys/kernel/config/usb_gadget does not exist."
        exit 0
    fi

    find /sys/kernel/config/usb_gadget \
        -maxdepth 3 \
        -type f \
        -readable \
        -print \
        2>/dev/null \
        | sort
    '


###############################################################################
# Cameras and media
###############################################################################

section 'Cameras and media graph'

show_glob \
    '/dev/video*' \
    'Video device nodes'

show_glob \
    '/dev/media*' \
    'Media controller device nodes'

run \
    'Media controller topology' \
    sh -c \
    '
    if ! command -v media-ctl >/dev/null 2>&1; then
        exit 127
    fi

    found=0

    for media in /dev/media*; do

        [ -e "$media" ] || continue

        found=1

        echo
        echo "===== $media ====="

        media-ctl -d "$media" -p

    done

    if [ "$found" -eq 0 ]; then
        echo "[NONE] No /dev/media* devices found."
    fi
    '

run \
    'V4L2 devices' \
    v4l2-ctl --list-devices


###############################################################################
# Suspend support
###############################################################################

section 'Suspend support'

show_glob \
    '/sys/power/state' \
    'Kernel suspend states'

show_glob \
    '/sys/power/mem_sleep' \
    'Kernel memory-sleep modes'

run \
    'Logind seat state' \
    loginctl show-seat seat0

printf '\n'
printf '%s\n' \
    '[INFO] This report intentionally does not suspend the tablet.'

printf '%s\n' \
    '[INFO] Perform the suspend/wake qualification manually.'


###############################################################################
# Services and boot health
###############################################################################

section 'Services and boot health'

run \
    'Failed systemd units' \
    systemctl \
        --failed \
        --no-pager \
        --full

run \
    'Power-profile ordering diagnostics' \
    systemctl \
        --no-pager \
        --full \
        status \
        rk-power-profile-sync.service \
        power-profiles-daemon.service

run \
    'Kernel warnings and errors this boot' \
    journalctl \
        -b \
        -k \
        -p warning..alert \
        --no-pager

run \
    'Release-relevant kernel messages' \
    sh -c \
    "
    dmesg \
        | grep -Eai \
        'oops|panic|BUG:|unable to handle|segfault|hung task|lockup|seekwave|skw|sv6160|regulatory.db|gsl|touch|rk817|charger|battery|suspend|wakeup|alsa|audio|bluetooth|hci|panfrost|drm|typec|husb320|dwc3|ov5648|dw9714|gc02m1|rknpu|autofs4|ordering cycle' \
        | tail -n 500
    "

# Prior to the C20e 2026-09-18 graphical-lock investigation, a real hard
# hang in the DRM/panel + Phosh path left zero trace: no /dev/watchdog,
# no hung_task/softlockup/hardlockup panic sysctls, and an empty pstore
# ramoops after the fact (see
# c20e-analysis/20260918-graphical-lock/probe3-recovery-summary.txt).
# These probes confirm that gap stays closed: the DW hardware watchdog
# (&wdt in the board DTS) is present and armed by systemd, and the
# kernel-side lockup detectors are compiled in and set to panic.
run \
    'Hardware watchdog device' \
    sh -c \
    "
    ls -la /dev/watchdog* 2>&1
    command -v wdctl >/dev/null 2>&1 && wdctl 2>&1
    "

run \
    'Lockup/hang panic sysctls' \
    sh -c \
    "
    for f in hung_task_panic softlockup_panic hardlockup_panic hung_task_timeout_secs; do
        if [ -r \"/proc/sys/kernel/\$f\" ]; then
            printf '%s = %s\n' \"\$f\" \"\$(cat /proc/sys/kernel/\$f)\"
        else
            printf '%s: sysctl not present (detector not compiled in)\n' \"\$f\"
        fi
    done
    "

run \
    'systemd watchdog arming' \
    systemctl \
        show \
        -p RuntimeWatchdogUSec \
        -p RebootWatchdogUSec \
        -p WatchdogDevice

run \
    'pstore/ramoops mount and contents' \
    sh -c \
    "
    mount | grep -i pstore
    ls -la /sys/fs/pstore/ 2>&1
    "


###############################################################################
# Additional system information
###############################################################################

section 'Additional system information'

run \
    'CPU information' \
    lscpu

run \
    'Memory information' \
    free -h

run \
    'Block devices' \
    lsblk \
        -o \
        NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS

run \
    'PCI devices' \
    lspci -nnk

run \
    'Platform devices' \
    sh -c \
    '
    find /sys/bus/platform/devices \
        -maxdepth 1 \
        -mindepth 1 \
        -printf "%f\n" \
        2>/dev/null \
        | sort
    '

run \
    'Device-tree model' \
    sh -c \
    '
    if [ -r /proc/device-tree/model ]; then

        tr "\0" "\n" </proc/device-tree/model

    else

        echo "[NONE] /proc/device-tree/model unavailable."

    fi
    '

run \
    'Device-tree compatible strings' \
    sh -c \
    '
    if [ -r /proc/device-tree/compatible ]; then

        tr "\0" "\n" </proc/device-tree/compatible

    else

        echo "[NONE] /proc/device-tree/compatible unavailable."

    fi
    '


###############################################################################
# Manual qualification checklist
###############################################################################

section 'Manual qualification still required'

cat <<'CHECKLIST'

[ ] Touchscreen responds across the full panel

[ ] Multi-touch operation verified

[ ] Touch coordinates remain correct after display rotation

[ ] Touchscreen functions correctly after suspend/resume

[ ] Battery charging verified

[ ] Battery discharge reporting verified

[ ] USB power-source transitions verified

[ ] Suspend for several minutes

[ ] Display wakes correctly after suspend

[ ] Touchscreen works after resume

[ ] Wi-Fi reconnects after resume

[ ] Audio works after resume

[ ] Speaker playback verified

[ ] Microphone capture verified

[ ] Headphone/audio-jack path verified if applicable

[ ] Bluetooth scan verified

[ ] Bluetooth pairing verified

[ ] Bluetooth connection verified

[ ] Bluetooth reconnect after reboot/resume verified

[ ] GPU renderer confirmed as Panfrost hardware acceleration

[ ] No software rendering fallback

[ ] USB-C device mode verified

[ ] USB-C host mode verified

[ ] USB mass-storage device verified

[ ] USB keyboard verified

[ ] Rear camera verified

[ ] Front camera verified

[ ] Camera autofocus behavior documented

[ ] Several-hour stability test completed

[ ] Wi-Fi traffic sustained during stability test

[ ] Charging sustained during stability test

[ ] No new kernel warnings/errors during stability test

CHECKLIST


###############################################################################
# Completion
###############################################################################

TOTAL_DURATION=$((SECONDS - SCRIPT_START_SECONDS))

printf '\n'
printf '===============================================================================\n'
printf 'Qualification collection complete\n'
printf '===============================================================================\n'

printf '\nChecks executed: %d\n' "$STEP_NUMBER"
printf 'Total runtime:   %s\n' "$(elapsed "$TOTAL_DURATION")"

printf '\n'
printf '%s\n' \
    'Review [WARN], [FAILED], [SKIP], [TIMEOUT], and [NONE] entries.'

printf '%s\n' \
    'Complete all manual qualification checks before signing off the hardware.'

progress \
    "COMPLETE" \
    "Hardware qualification report finished - $STEP_NUMBER checks, $(elapsed "$TOTAL_DURATION")"

if [[ -n "$OUTPUT" ]]; then
    progress \
        "REPORT" \
        "Saved detailed report to: $OUTPUT"
fi

exec 3>&-