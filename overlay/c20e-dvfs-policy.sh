#!/bin/bash
# Pin the DDR frequency on the C20e.
#
# Without this the dmc devfreq governor (dmc_ondemand) scales DRAM while the
# driver is unable to read the display's bandwidth requirements:
#
#   rockchip-vop2 ff400000.vop: failed to init opp info
#   rockchip-dmc dmc: failed to get vop bandwidth to dmc rate
#   rockchip-dmc dmc: failed to get vop pn to msch rl
#
# The result is memory corruption once the graphical session is scanning out.
# It presents as corrupted program counters, SP/PC alignment exceptions and
# oopses in the idle task -- below the allocator, so slub_debug=FZPU with full
# red-zoning and poisoning stays silent. Boots to multi-user.target were clean;
# boots to graphical.target panicked within 30s. Pinning the governor kept a
# graphical session alive with zero oopses.
LOG=/var/log/c20e-dvfs-policy.log
exec >>"$LOG" 2>&1
echo "=== c20e dvfs policy $(date -Is) ==="

for d in /sys/class/devfreq/*dmc* /sys/class/devfreq/dmc; do
    [ -d "$d" ] || continue
    echo "device: $d"
    echo "  before: $(cat "$d/governor" 2>/dev/null) @ $(cat "$d/cur_freq" 2>/dev/null)"
    if echo performance > "$d/governor" 2>/dev/null; then
        echo "  after:  $(cat "$d/governor" 2>/dev/null) @ $(cat "$d/cur_freq" 2>/dev/null)"
    else
        echo "  FAILED to set governor"
    fi
done
exit 0
