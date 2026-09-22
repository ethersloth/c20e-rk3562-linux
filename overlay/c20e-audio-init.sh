#!/bin/sh
# Route RK817 audio to the speaker at boot. The codec driver defaults
# 'Playback Path' to OFF, so with nothing setting it PipeWire plays into a
# codec with no output: the speaker amp GPIO (spk-ctl, driven by the codec on
# stream unmute) only goes high when the path is SPK. Fedora had no sound
# until this was set (2026-09-21). Same settings as the Debian image's
# rk-audio-init.sh (build_rootfs.sh), which this mirrors.
#
# Note: the card-level 'spk switch'/'hp switch' controls always read "off" on
# this board -- the DT sound node has no spk-con-gpios, so they are no-ops.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

card="$(awk '/rk817|rockchip-rk817/ {print $1; exit}' /proc/asound/cards 2>/dev/null | tr -d ' ' || true)"
[ -n "$card" ] || { echo "no rk817 sound card"; exit 0; }

# Twice, to survive late register resets while the codec settles.
for pass in 1 2; do
    amixer -q -c "$card" cset name='Resume Path' ON || true
    amixer -q -c "$card" cset name='Playback Path' OFF || true
    sleep 1
    for path in SPK SPK_HP HP RCV; do
        amixer -q -c "$card" cset name='Playback Path' "$path" && break
    done
    amixer -q -c "$card" cset name='DAC Playback Volume' 230,230 || true
    amixer -q -c "$card" cset name='Speaker Switch' on || true
    amixer -q -c "$card" cset name='Capture MIC Path' 'Main Mic' || true
    amixer -q -c "$card" cset name='Main Mic Switch' on || true
    amixer -q -c "$card" cset name='Headset Mic Switch' off || true
    amixer -q -c "$card" cset name='ADC Capture Volume' 255,255 || true
done
echo "rk817 card $card: Playback Path=$(amixer -c "$card" cget name='Playback Path' | sed -n 's/.*: values=//p')"
alsactl store >/dev/null 2>&1 || true
