/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: pie-grow-partition [-n] DISK INDEX
 *
 * Extends MBR partition INDEX (1 to 4) of the raw disk DISK to the end of
 * the disk, if it is the disk's last partition, while its slices stay in
 * use: DISK is opened with a shared lock, and the kernel rescans the
 * partitions when it is closed. Nothing else in the MBR changes. An MBR
 * partition ends within the first 2 TiB, so on a larger disk it ends
 * there. A disk with an extended partition is not changed. -n only says
 * what it would do. It exits 0 when the partition reaches its end, as the
 * kernel sees it, 1 when it changes nothing, 2 on a usage error, 3 when
 * writing the MBR failed and the original could not be written back, and
 * 4 when the kernel's slice is not yet the size the MBR gives, or its
 * size cannot be read. In that case the kernel takes the new size at the
 * next boot.
 */
#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <unistd.h>

static uint32_t
get32(const unsigned char *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void
put32(unsigned char *p, uint32_t v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

static void
check_slice(const char *disk, int idx, uint64_t want)
{
	char slice[1024];
	uint64_t count = 0;
	if (snprintf(slice, sizeof(slice), "%ss%d", disk, idx) >= (int)sizeof(slice))
		errx(4, "%s: the name is too long", disk);
	int sfd = open(slice, O_RDONLY);
	if (sfd < 0 || ioctl(sfd, DKIOCGETBLOCKCOUNT, &count) != 0)
		err(4, "%s", slice);
	close(sfd);
	if (count != want)
		errx(4, "%s: the kernel still sees %llu blocks; the new size takes effect at the next boot",
		    slice, (unsigned long long)count);
}

int
main(int argc, char *argv[])
{
	int dry = 0;
	if (argc > 1 && strcmp(argv[1], "-n") == 0) {
		dry = 1;
		argv++;
		argc--;
	}
	if (argc != 3 || argv[2][0] < '1' || argv[2][0] > '4' || argv[2][1] != '\0') {
		fprintf(stderr, "usage: pie-grow-partition [-n] DISK INDEX\n");
		return 2;
	}
	int idx = argv[2][0] - '0';
	int fd = open(argv[1], (dry ? O_RDONLY : O_RDWR) | O_SHLOCK);
	if (fd < 0)
		err(1, "%s", argv[1]);
	uint64_t count = 0;
	uint32_t bs = 0;
	if (ioctl(fd, DKIOCGETBLOCKCOUNT, &count) != 0 || ioctl(fd, DKIOCGETBLOCKSIZE, &bs) != 0)
		err(1, "%s: cannot read its size", argv[1]);
	if (bs != 512)
		errx(1, "%s: blocks of %u bytes, not 512", argv[1], bs);
	unsigned char mbr[512];
	if (pread(fd, mbr, sizeof(mbr), 0) != (ssize_t)sizeof(mbr))
		err(1, "%s: cannot read the MBR", argv[1]);
	if (mbr[510] != 0x55 || mbr[511] != 0xaa)
		errx(1, "%s: no MBR", argv[1]);
	for (int i = 0; i < 4; i++) {
		unsigned char t = mbr[446 + 16 * i + 4];
		if (t == 0xee)
			errx(1, "%s: a GPT disk; only an MBR is changed", argv[1]);
		if (t == 0x05 || t == 0x0f || t == 0x85)
			errx(1, "%s: partition %d is an extended partition", argv[1], i + 1);
	}
	unsigned char *e = mbr + 446 + 16 * (idx - 1);
	uint64_t start = get32(e + 8), size = get32(e + 12);
	if (e[4] == 0 || size == 0)
		errx(1, "%s: partition %d is empty", argv[1], idx);
	if (start == 0 || start + size > count)
		errx(1, "%s: partition %d does not fit the disk", argv[1], idx);
	for (int i = 0; i < 4; i++) {
		unsigned char *o = mbr + 446 + 16 * i;
		uint64_t os = get32(o + 8), on = get32(o + 12);
		if (i == idx - 1 || o[4] == 0 || on == 0)
			continue;
		if (os + on > start)
			errx(1, "%s: partition %d does not end before partition %d", argv[1], i + 1, idx);
	}
	uint64_t end = count > UINT32_MAX ? UINT32_MAX : count;
	if (start + size >= end) {
		printf("pie-grow-partition: %s partition %d already reaches the end\n", argv[1], idx);
		if (!dry)
			check_slice(argv[1], idx, size);
		return 0;
	}
	uint32_t nsize = (uint32_t)(end - start);
	printf("pie-grow-partition: %s partition %d: %llu to %u blocks\n", argv[1], idx,
	    (unsigned long long)size, nsize);
	if (dry)
		return 0;
	unsigned char old[512], check[512];
	memcpy(old, mbr, sizeof(old));
	put32(e + 12, nsize);
	e[5] = 0xfe;
	e[6] = 0xff;
	e[7] = 0xff;
	if (pwrite(fd, mbr, sizeof(mbr), 0) != (ssize_t)sizeof(mbr) || ioctl(fd, DKIOCSYNCHRONIZECACHE) != 0 ||
	    pread(fd, check, sizeof(check), 0) != (ssize_t)sizeof(check) || memcmp(check, mbr, sizeof(mbr)) != 0) {
		warnx("%s: cannot write the MBR", argv[1]);
		if (pwrite(fd, old, sizeof(old), 0) == (ssize_t)sizeof(old) && ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0 &&
		    pread(fd, check, sizeof(check), 0) == (ssize_t)sizeof(check) && memcmp(check, old, sizeof(old)) == 0)
			errx(1, "%s: the original MBR is back", argv[1]);
		errx(3, "%s: the MBR may be damaged", argv[1]);
	}
	if (close(fd) != 0)
		err(4, "%s: close", argv[1]);
	check_slice(argv[1], idx, nsize);
	return 0;
}
