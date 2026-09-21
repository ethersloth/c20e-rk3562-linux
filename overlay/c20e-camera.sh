#!/bin/bash
# Configure a C20e camera pipeline.  Usage: c20e-camera [rear|front|status]
#
# Hardware layout, both sensors verified working on this board:
#
#   REAR   OV5648   i2c 4-0036  csi2-dphy0  media0 rkcif-mipi-lvds
#                   SBGGR10_1X10 2592x1944@15  raw on /dev/video0
#                   autofocus: dw9714 at i2c 4-000c
#   FRONT  GC02M1   i2c 4-0037  csi2-dphy4  media1 rkcif-mipi-lvds2
#                   SRGGB10_1X10 1600x1200@30  raw on /dev/video11
#
# There is only ONE ISP (media2 / rkisp0), so the two cameras contend for it.
# Selecting one MUST disable the other's link first, or the ISP keeps the stale
# input and output is wrong or absent.
#
# rkisp-isp-subdev pad0 is MUST_CONNECT. If no input link is enabled, streaming
# from the ISP node returns zero bytes and the kernel logs NOTHING AT ALL --
# which is why the cameras looked dead for so long despite working hardware.
#
# Raw Bayer is always available on the per-sensor CIF node without the ISP, and
# that is the reliable path for BOTH sensors.
#
# ISP caveat, measured on hardware: rkisp sizes itself for whichever sensor is
# linked when it first initialises, and does not fully reconfigure on a switch.
# Selecting the other camera moves the link and the pad formats correctly, but
# streaming from the ISP node then returns nothing. The input crop even stays
# stale and self-inconsistent across the switch:
#
#   crop.bounds:(0,0)/1600x1200   crop:(0,0)/2592x1944
#
# Resetting the crop by hand is not sufficient. So: the camera you want through
# the ISP should be the one selected at BOOT by c20e-camera.service (rear by
# default; change its ExecStart to "front" to swap). Switching at runtime is
# fine for the raw nodes, which never go through the ISP.
#
# ISP gain: there is no 3A (Rockchip's rkaiq is proprietary and we do not have
# it), so ISP digital gain must be fed manually or the output is nearly black.
# c20e-isp-gain does that. Measured on this board, ISP luma vs gain (Q8,
# 256=1.0x), dim indoor scene:
#
#   no feeder   Y=4.9      1024 (4x)  Y=74    <- well exposed
#   256 (1x)    Y=5.0      2048 (8x)  Y=240   <- blown
#   512 (2x)    Y=19       3072       Y=254   <- saturated
#
# 4096 overflows the field and yields Y=0. ISP_GAIN below defaults to 1024.
#
# This needs the VENDOR ABI. The board runs CONFIG_VIDEO_ROCKCHIP_ISP with
# isp_ver=ISP_V32_L, so params are struct isp32_isp_params_cfg (11145 bytes)
# from <linux/rk-isp32-config.h>. tools/rkisp1_awb.c targets MAINLINE rkisp1
# (struct rkisp1_params_cfg, 3048 bytes) and does nothing here at all: feeding
# it 8x on every channel moved luma from 4.99 to 5.13.
set -u

CAM="${1:-rear}"
ISP=/dev/media2
ISP_NODE=${ISP_NODE:-/dev/video22}

log(){ echo "[c20e-camera] $*"; }

sensor_subdev(){   # $1 = media device, $2 = entity substring
    local ent
    ent=$(media-ctl -d "$1" -p 2>/dev/null | grep -o "m0[0-9]_[bf]_$2 [0-9-]*" | head -1)
    [ -n "$ent" ] || return 1
    for s in /dev/v4l-subdev*; do
        v4l2-ctl -d "$s" --list-ctrls 2>/dev/null | grep -q 'analogue_gain' || continue
        # match by reported pixel_rate, which differs between the two sensors
        echo "$s"
    done
}

case "$CAM" in
status)
    echo "--- ISP input links ---"
    media-ctl -d "$ISP" -p 2>/dev/null | grep -E 'rkcif-mipi-lvds2?":0' || true
    echo "--- sensors ---"
    media-ctl -d /dev/media0 -p 2>/dev/null | grep -o 'm00_b_[a-z0-9]* [0-9-]*' | head -1
    media-ctl -d /dev/media1 -p 2>/dev/null | grep -o 'm01_f_[a-z0-9]* [0-9-]*' | head -1
    exit 0 ;;
rear)
    CIF_ENTITY="rkcif-mipi-lvds";  OTHER="rkcif-mipi-lvds2"
    SENSOR_FMT="SBGGR10_1X10/2592x1944" ;;
front)
    CIF_ENTITY="rkcif-mipi-lvds2"; OTHER="rkcif-mipi-lvds"
    SENSOR_FMT="SRGGB10_1X10/1600x1200" ;;
*)
    echo "usage: $0 [rear|front|status]" >&2; exit 1 ;;
esac

W=${WIDTH:-1280}; H=${HEIGHT:-960}

# Is a given CIF entity currently linked into the ISP?
link_enabled(){
    media-ctl -d "$ISP" -p 2>/dev/null \
        | grep -F "\"$1\":0" | grep -q ENABLED
}

# Only toggle links that actually need changing. media-ctl returns
# "Device or resource busy (16)" when asked to re-apply a link that is already
# in the requested state, which otherwise looks like a hard failure.
if link_enabled "$OTHER"; then
    media-ctl -d "$ISP" -l "\"$OTHER\":0 -> \"rkisp-isp-subdev\":0 [0]" 2>/dev/null \
        || log "warning: could not drop $OTHER (still streaming?)"
fi
if link_enabled "$CIF_ENTITY"; then
    log "$CIF_ENTITY already feeding the ISP"
else
    media-ctl -d "$ISP" -l "\"$CIF_ENTITY\":0 -> \"rkisp-isp-subdev\":0 [1]" 2>/dev/null \
        || { log "ERROR: could not enable $CIF_ENTITY -> rkisp-isp-subdev"; exit 1; }
fi

media-ctl -d "$ISP" --set-v4l2 "\"rkisp-isp-subdev\":0 [fmt:$SENSOR_FMT]" 2>/dev/null
media-ctl -d "$ISP" --set-v4l2 "\"rkisp-isp-subdev\":2 [fmt:YUYV8_2X8/${W}x${H}]" 2>/dev/null
# Also pin the CIF bridge pad and the ISP input crop. The crop otherwise keeps
# the previous sensor's size and no frames ever arrive.
media-ctl -d "$ISP" --set-v4l2 "\"$CIF_ENTITY\":0 [fmt:$SENSOR_FMT]" 2>/dev/null
media-ctl -d "$ISP" --set-v4l2 "\"rkisp-isp-subdev\":0 [crop:(0,0)/${SENSOR_FMT#*/}]" 2>/dev/null

# Max out sensor gain/exposure: with no 3A this is the only exposure control.
for s in /dev/v4l-subdev*; do
    v4l2-ctl -d "$s" --list-ctrls 2>/dev/null | grep -q 'analogue_gain' || continue
    gmax=$(v4l2-ctl -d "$s" --list-ctrls 2>/dev/null | sed -n 's/.*analogue_gain.*max=\([0-9]*\).*/\1/p')
    emax=$(v4l2-ctl -d "$s" --list-ctrls 2>/dev/null | sed -n 's/.*exposure.*max=\([0-9]*\).*/\1/p')
    [ -n "${gmax:-}" ] && v4l2-ctl -d "$s" --set-ctrl=analogue_gain="${SENSOR_GAIN:-$gmax}" 2>/dev/null
    [ -n "${emax:-}" ] && v4l2-ctl -d "$s" --set-ctrl=exposure="${SENSOR_EXPOSURE:-$emax}" 2>/dev/null
    v4l2-ctl -d "$s" --set-ctrl=test_pattern=0 2>/dev/null
done

# Start the ISP gain feeder; without it the ISP output is nearly black.
ISP_GAIN=${ISP_GAIN:-1024}
if [ "$ISP_GAIN" != "0" ] && command -v c20e-isp-gain >/dev/null 2>&1; then
    pkill -f "c20e-isp-gain" 2>/dev/null
    setsid c20e-isp-gain "$ISP_GAIN" >/var/log/c20e-isp-gain.log 2>&1 &
    log "ISP gain feeder started at $ISP_GAIN (Q8, 256=1.0x)"
fi

log "$CAM camera ready on $ISP_NODE (NV12 ${W}x${H})"
log "raw Bayer: rear=/dev/video0  front=/dev/video11"
exit 0
