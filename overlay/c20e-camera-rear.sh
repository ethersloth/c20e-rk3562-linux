#!/bin/bash
# Bring up the C20e rear camera (OV5648) pipeline.
#
# The sensor, CSI-2 receiver and CIF all work with no driver or DTS changes --
# the camera was never broken, nothing had ever configured the graph. Proven
# with the sensor's own test pattern (clean vertical colour bars) and with real
# photographs.
#
# Two usable outputs:
#
#   /dev/video0   raw Bayer SBGGR10 2592x1944 straight off the CIF. Works with
#                 no extra setup; needs a userspace debayer.
#   /dev/video22  NV12 via the ISP (rkisp_mainpath), which any normal app can
#                 consume. This is what the script configures.
#
# The ISP input link is NOT enabled at boot, and its pad0 is MUST_CONNECT, so
# without the media-ctl link below streaming from /dev/video22 silently returns
# zero bytes with no kernel error at all.
#
# Known limitation: the ISP's digital gain is driven by Rockchip's proprietary
# rkaiq 3A library, which we do not have. Without it the ISP applies minimum
# gain and images come out dark -- ISP Y mean tracks sensor gain linearly
# (gain 32/140/248 -> Y 5.6/9.9/13.0), so the path is correct, just starved.
# Until 3A exists, set sensor gain/exposure manually (see SENSOR_GAIN below) or
# capture raw from /dev/video0 and debayer in userspace.
set -u

MEDIA_ISP=${MEDIA_ISP:-/dev/media2}
WIDTH=${WIDTH:-1280}
HEIGHT=${HEIGHT:-960}
SENSOR_GAIN=${SENSOR_GAIN:-248}      # 16..248
SENSOR_EXPOSURE=${SENSOR_EXPOSURE:-1900}  # 4..1980

log(){ echo "[c20e-camera-rear] $*"; }

# Find the OV5648 subdev by its controls rather than a fixed node number.
SENSOR_SD=""
for s in /dev/v4l-subdev*; do
    if v4l2-ctl -d "$s" --list-ctrls 2>/dev/null | grep -q 'analogue_gain'; then
        SENSOR_SD="$s"; break
    fi
done
[ -n "$SENSOR_SD" ] || { log "ERROR: OV5648 subdev not found"; exit 1; }
log "sensor subdev: $SENSOR_SD"

# MUST_CONNECT sink: without this, /dev/video22 streams nothing and says nothing.
media-ctl -d "$MEDIA_ISP" -l '"rkcif-mipi-lvds":0 -> "rkisp-isp-subdev":0 [1]' 2>/dev/null \
    || { log "ERROR: could not enable rkcif-mipi-lvds -> rkisp-isp-subdev"; exit 1; }

media-ctl -d "$MEDIA_ISP" --set-v4l2 '"rkisp-isp-subdev":0 [fmt:SBGGR10_1X10/2592x1944]' 2>/dev/null
media-ctl -d "$MEDIA_ISP" --set-v4l2 "\"rkisp-isp-subdev\":2 [fmt:YUYV8_2X8/${WIDTH}x${HEIGHT}]" 2>/dev/null

v4l2-ctl -d "$SENSOR_SD" --set-ctrl=test_pattern=0      2>/dev/null
v4l2-ctl -d "$SENSOR_SD" --set-ctrl=analogue_gain="$SENSOR_GAIN"  2>/dev/null
v4l2-ctl -d "$SENSOR_SD" --set-ctrl=exposure="$SENSOR_EXPOSURE"   2>/dev/null

log "rear camera ready: /dev/video22 (NV12 ${WIDTH}x${HEIGHT}), raw Bayer on /dev/video0"
log "test: v4l2-ctl -d /dev/video22 --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=NV12 --stream-mmap --stream-count=5 --stream-to=/tmp/f.nv12"
exit 0
