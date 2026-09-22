#!/bin/bash
# Pick the C20e USB-C port's data role automatically.
#
# The port is either a USB DEVICE (the /dev/ttyGS0 console gadget, for a
# laptop) or a USB HOST (hubs, keyboards, mouse dongles). The HUSB320 is a
# plain Type-C CC controller without USB Power Delivery, so it cannot tell a
# laptop from a charging hub: both present Rp (a power source), which makes
# the tablet the power sink AND the data device. A charging hub then never
# enumerates (seen 2026-09-22: hub + Logitech receiver invisible until the
# controller was switched to host by hand, then both enumerated at once).
#
# Policy -- decided only when something is plugged or unplugged, so the port
# never flaps (the old usb-role-manager poller fought the gadget; this one
# uses the gadget's own state to decide):
#   nothing attached                -> device mode, console gadget bound
#   partner is a sink (we are DFP:  -> host mode (OTG adapter, unpowered hub)
#     data_role "[host]")
#   partner is a source             -> device mode for $PROBE s; if a USB host
#                                      configures the gadget it is a laptop:
#                                      stay. Otherwise charger / charging hub:
#                                      host mode.
G=/sys/kernel/config/usb_gadget/c20e
UDC=fe500000.usb
PORT=/sys/class/typec/port0
PARTNER=/sys/class/typec/port0-partner
PHY=/sys/devices/platform/ff740000.usb2-phy/otg_mode
DBG=/sys/kernel/debug/usb/$UDC/mode
PROBE=5

log(){ echo "c20e-usb-role: $*"; }
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug

set_device(){
    echo peripheral > "$PHY" 2>/dev/null
    echo device > "$DBG" 2>/dev/null
    for _ in $(seq 1 30); do [ -e /sys/class/udc/$UDC ] && break; sleep 0.2; done
    [ -d "$G" ] && [ -z "$(cat "$G/UDC" 2>/dev/null)" ] && echo "$UDC" > "$G/UDC" 2>/dev/null
    log "device mode (console gadget: $(cat "$G/UDC" 2>/dev/null || echo none))"
}
set_host(){
    [ -d "$G" ] && echo "" > "$G/UDC" 2>/dev/null
    echo host > "$PHY" 2>/dev/null
    echo host > "$DBG" 2>/dev/null
    log "host mode"
}
decide(){
    if [ ! -e "$PARTNER" ]; then set_device; return; fi
    role="$(grep -o '\[[a-z]*\]' "$PORT/data_role" 2>/dev/null)"
    if [ "$role" = "[host]" ]; then
        log "partner is a sink (tablet powers it): OTG device or unpowered hub"
        set_host; return
    fi
    set_device
    for _ in $(seq 1 $((PROBE * 5))); do
        [ "$(cat /sys/class/udc/$UDC/state 2>/dev/null)" = configured ] && { log "a USB host configured the gadget: staying a device"; return; }
        [ -e "$PARTNER" ] || return
        sleep 0.2
    done
    log "power source attached but no USB host after ${PROBE}s: charger or charging hub"
    set_host
}

# Wait for the console gadget to exist (c20e-usb-debug creates it).
for _ in $(seq 1 50); do [ -d "$G" ] && break; sleep 0.2; done
last=unset
while :; do
    now=absent; [ -e "$PARTNER" ] && now=present
    if [ "$now" != "$last" ]; then
        log "partner $now"
        decide
        last=$now
    fi
    sleep 1
done
