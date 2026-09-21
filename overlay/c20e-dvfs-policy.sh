#!/bin/bash
# Pin the DDR frequency on the C20e.
#
# Without this, the dmc devfreq governor (dmc_ondemand) scales DRAM between
# 528MHz and 920MHz, and the board corrupts memory once the graphical session
# is scanning out. Pinning the governor stops the transitions and the
# corruption stops with them.
#
# Evidence for the fix is strong: boots to multi-user.target were clean, boots
# to graphical.target panicked within 30s, and with the governor pinned the
# same graphical session has run for hours with zero oopses. The failures
# present as corrupted program counters, SP/PC alignment exceptions and oopses
# in the idle task, with slub_debug=FZPU silent -- damage below the allocator.
#
# The MECHANISM is NOT established. An earlier version of this comment blamed
# these boot messages:
#
#   rockchip-dmc dmc: failed to get vop bandwidth to dmc rate
#   rockchip-dmc dmc: failed to get vop pn to msch rl
#
# That was wrong. Those properties (vop-bw-dmc-freq, vop-pn-msch-readlatency)
# are RK3399-era: 0 of 31 rk3562 board DTS files set them, 0 of 78 rk3568, 0 of
# 77 rk3588. Every RK3562 board logs those errors. They are noise, not cause.
#
# What is actually wrong is most likely DDR timing being marginal at the lower
# operating points, or the frequency transitions themselves being unsafe on
# this board's memory. Until that is understood, do not encode a specific
# theory in the DTS -- pin the governor, which is what is actually tested.
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
