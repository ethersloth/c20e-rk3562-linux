# Seekwave Bluetooth NV firmware

`skwbt` requests `seekwave/sv6160.nvbin` (the `seekwave/` prefix comes from
`options skwbt firmware_dir=seekwave`). Without it Bluetooth gets as far as
talking to the controller and then stops:

    btseekwave_rx_complete, chip version:0x17
    init cmd response: 0x100101
    request seekwave/sv6160.nvbin -> -2
    nv file load fail, BT Controller Version:0x0017

and the vendor error path then oopses in `close_sdio_port` -> `complete()`,
which is where the boot-time trace came from.

`sv6160.nvbin` here is the **for_rockchip / android_13** build from the vendor
drop, since this board is a Rockchip RK3562. `sv6160.nvbin.generic-fallback`
(md5 074c618e58d6ca835332039c5102b669) is the generic variant that also ships
under overlay/drivers/net/wireless/ea6621q/swtbt4l/. If RF behaviour looks
wrong, swap them and retest -- they are both 354 bytes and differ in content.
