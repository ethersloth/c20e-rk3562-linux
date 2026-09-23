#!/bin/bash
# Feed the C20e's ISP capture node into the v4l2loopback device, so ordinary
# applications can use the camera.
#
# WHY: the ISP node is multiplanar V4L2 (see c20e-v4l2loopback-modprobe.conf) and
# Qt, PipeWire and libcamera all refuse it. This pipeline is the only thing that
# touches the multiplanar node; everything else reads the loopback device.
#
# The source is whichever camera c20e-camera linked to the ISP at boot (rear by
# default). There is one ISP for both sensors and it sizes itself at first init,
# so switching sensors afterwards needs `c20e-camera front|rear` AND a restart of
# this bridge -- and on this board a runtime switch often yields no frames, so a
# reboot is the reliable way to change cameras.
#
# Output is YUY2 by default because every application accepts it; NV12 costs no
# conversion but some applications reject it. Override in
# /etc/default/c20e-camera-bridge.
#   usage: c20e-camera-bridge run|start|stop|status
set -u

CONF=/etc/default/c20e-camera-bridge
# shellcheck disable=SC1090
[[ -r $CONF ]] && . "$CONF"
SRC="${C20E_CAM_SRC:-/dev/video22}"
SINK="${C20E_CAM_SINK:-/dev/video40}"
WIDTH="${C20E_CAM_WIDTH:-1280}"
HEIGHT="${C20E_CAM_HEIGHT:-720}"
# Left empty on purpose: the ISP offers a CONTINUOUS 1-15 fps at 720p (the rear
# OV5648 runs 2592x1944 at 15 fps and the main path inherits that), so pinning a
# rate in the caps fails negotiation outright -- "not-negotiated (-4)". Set
# C20E_CAM_FPS only to cap the rate below what the sensor gives.
FPS="${C20E_CAM_FPS:-}"
FMT="${C20E_CAM_FORMAT:-YUY2}"
UNIT=c20e-camera-bridge.service

case "${1:-run}" in
run)
    [[ -e $SRC  ]] || { echo "no ISP capture node at $SRC (is c20e-camera.service up?)" >&2; exit 1; }
    [[ -e $SINK ]] || { echo "no loopback device at $SINK (is v4l2loopback loaded?)" >&2; exit 1; }
    # io-mode=0 keeps the source on plain mmap buffers: the DMABUF path on this
    # ISP driver stalls under some consumers. leaky=downstream means a slow
    # application drops frames instead of blocking the ISP.
    exec gst-launch-1.0 --no-fault -q \
        v4l2src device="$SRC" io-mode=0 do-timestamp=true \
        ! video/x-raw,format=NV12,width="$WIDTH",height="$HEIGHT"${FPS:+,framerate=$FPS/1} \
        ! queue max-size-buffers=4 leaky=downstream \
        ! videoconvert \
        ! video/x-raw,format="$FMT" \
        ! v4l2sink device="$SINK" sync=false
    ;;
start)
    systemctl --user start "$UNIT" || exit 1
    for _ in $(seq 20); do
        v4l2-ctl -d "$SINK" --all 2>/dev/null | grep -q "Format Video Capture" && break
        sleep 0.25
    done
    # PipeWire reads a V4L2 device's capabilities when udev announces it, and
    # with exclusive_caps=1 the loopback only claims CAPTURE while this bridge is
    # attached -- so at boot PipeWire saw an output-only device and published no
    # camera. Nothing re-announces it (the capability changes without a udev
    # event), so re-probe here, once, if the camera is not in the graph yet.
    # Applications that go through PipeWire -- GNOME Snapshot, Cheese, anything
    # using the portal -- need this; Chrome opens V4L2 directly and does not.
    if command -v wpctl >/dev/null && ! wpctl status 2>/dev/null | grep -q "C20e Camera (V4L2)"; then
        systemctl --user restart wireplumber 2>/dev/null || true
        sleep 3
    fi
    ;;
stop)   systemctl --user stop "$UNIT" ;;
status) systemctl --user status --no-pager "$UNIT" ;;
*)      echo "usage: ${0##*/} run|start|stop|status" >&2; exit 2 ;;
esac
