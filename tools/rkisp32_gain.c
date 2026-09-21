/* rkisp32_gain.c -- ISP gain feeder for the Rockchip vendor ISP (ISP_V32_L).
 *
 * The C20e runs CONFIG_VIDEO_ROCKCHIP_ISP (Rockchip's vendor driver), and
 * rk3562 matches isp_ver = ISP_V32_L. Its params ABI is
 * struct isp32_isp_params_cfg from <linux/rk-isp32-config.h>.
 *
 * tools/rkisp1_awb.c targets MAINLINE rkisp1 (struct rkisp1_params_cfg, 3048
 * bytes) and cannot work here: VIDIOC_G_FMT on /dev/video28 fails outright and
 * the gains have no effect. Measured, feeding mainline params at 8x on every
 * channel moved ISP luma from 4.99 to 5.13 -- i.e. not at all.
 *
 * isp32's AWB gain block is also shaped differently: three gain sets
 * (gain0/gain1/gain2) plus a separate awb1 set, not mainline's single set.
 * All of them are written here, since which one is live depends on the
 * pipeline configuration.
 *
 * Gains are Q8: 256 = 1.0x.
 *
 * Usage: rkisp32_gain [gain]            all channels
 *        rkisp32_gain [r gr gb b]       per channel
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <linux/rk-isp32-config.h>

#define NBUF 4

int main(int argc, char **argv)
{
	unsigned r = 256, gr = 256, gb = 256, b = 256;
	const char *dev = getenv("ISP_PARAMS_DEV");
	if (!dev) dev = "/dev/video28";

	if (argc == 2) r = gr = gb = b = (unsigned)atoi(argv[1]);
	else if (argc == 5) { r = atoi(argv[1]); gr = atoi(argv[2]);
			      gb = atoi(argv[3]); b = atoi(argv[4]); }

	int fd = open(dev, O_RDWR);
	if (fd < 0) { perror(dev); return 1; }

	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof fmt);
	fmt.type = V4L2_BUF_TYPE_META_OUTPUT;
	fmt.fmt.meta.dataformat = V4L2_META_FMT_RK_ISP1_PARAMS;
	fmt.fmt.meta.buffersize = sizeof(struct isp32_isp_params_cfg);
	if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
		fprintf(stderr, "S_FMT failed: %s (buffersize %zu)\n",
			strerror(errno), sizeof(struct isp32_isp_params_cfg));
		return 1;
	}

	struct v4l2_requestbuffers req;
	memset(&req, 0, sizeof req);
	req.count = NBUF; req.type = V4L2_BUF_TYPE_META_OUTPUT;
	req.memory = V4L2_MEMORY_MMAP;
	if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) { perror("REQBUFS"); return 1; }

	void *maps[NBUF];
	for (unsigned i = 0; i < req.count; i++) {
		struct v4l2_buffer buf;
		memset(&buf, 0, sizeof buf);
		buf.type = V4L2_BUF_TYPE_META_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP; buf.index = i;
		if (ioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) { perror("QUERYBUF"); return 1; }
		maps[i] = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
			       MAP_SHARED, fd, buf.m.offset);
		if (maps[i] == MAP_FAILED) { perror("mmap"); return 1; }

		struct isp32_isp_params_cfg *p = maps[i];
		memset(p, 0, sizeof *p);
		p->module_en_update  = ISP32_MODULE_AWB_GAIN;
		p->module_ens        = ISP32_MODULE_AWB_GAIN;
		p->module_cfg_update = ISP32_MODULE_AWB_GAIN;

		struct isp32_awb_gain_cfg *g = &p->others.awb_gain_cfg;
		g->awb1_gain_gb = gb; g->awb1_gain_gr = gr;
		g->awb1_gain_b  = b;  g->awb1_gain_r  = r;
		g->gain0_green_b = gb; g->gain0_green_r = gr;
		g->gain0_blue    = b;  g->gain0_red     = r;
		g->gain1_green_b = gb; g->gain1_green_r = gr;
		g->gain1_blue    = b;  g->gain1_red     = r;
		g->gain2_green_b = gb; g->gain2_green_r = gr;
		g->gain2_blue    = b;  g->gain2_red     = r;

		buf.bytesused = sizeof *p;
		if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) { perror("QBUF"); return 1; }
	}

	int type = V4L2_BUF_TYPE_META_OUTPUT;
	if (ioctl(fd, VIDIOC_STREAMON, &type) < 0) { perror("STREAMON"); return 1; }
	fprintf(stderr, "rkisp32_gain: R=%u Gr=%u Gb=%u B=%u on %s (Q8, 256=1.0x)\n",
		r, gr, gb, b, dev);

	for (;;) {
		struct v4l2_buffer buf;
		memset(&buf, 0, sizeof buf);
		buf.type = V4L2_BUF_TYPE_META_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP;
		if (ioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
			if (errno == EINTR) continue;
			perror("DQBUF"); break;
		}
		buf.bytesused = sizeof(struct isp32_isp_params_cfg);
		if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) { perror("QBUF"); break; }
	}
	ioctl(fd, VIDIOC_STREAMOFF, &type);
	close(fd);
	return 0;
}
