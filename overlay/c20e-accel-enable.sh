#!/usr/bin/python3
# Start the C20e accelerometer (MiraMEMS DA223 at i2c 2-0027, input "gsensor").
#
# Rockchip's vendor sensor framework registers the chip as an INPUT device but
# leaves it powered off until something issues GSENSOR_IOCTL_START on its
# misc node -- on Android that was the sensor HAL. Until then the input device
# never reports. The driver's release() does not stop it, so one ioctl at boot
# is enough (verified: ~80 events/s continue after this exits).
#
# The other gsensor node in the DT (sc7a20 at 0x19) is not populated on this
# board; its probe fails with -2, which is expected.
import fcntl, os, sys
GSENSOR_IOCTL_START = 0x6103   # _IO('a', 0x03), include/linux/sensor-dev.h
try:
    fd = os.open("/dev/mma8452_daemon", os.O_RDWR)
except OSError as e:
    print(f"no accelerometer misc device: {e}"); sys.exit(0)
fcntl.ioctl(fd, GSENSOR_IOCTL_START)
os.close(fd)
print("accelerometer started")
