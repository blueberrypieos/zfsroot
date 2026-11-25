/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: pie-grow-partition [-n] DISK INDEX
 *
 * Extends MBR partition INDEX, 1 to 4, of the raw disk DISK, if it is the
 * disk's last partition, while its slices stay in use. The partition then
 * ends 2048 blocks before the disk ends. That last MiB stays out of every
 * partition. DISK is opened with a shared lock, and the kernel rescans the
 * partitions when it is closed. Nothing else in the MBR changes. An MBR
 * partition ends within the first 2 TiB, so on a larger disk it ends
 * there. A disk with an extended partition is not changed.
 *
 * Block 1 may hold PIE's GPT: a header whose 128 entries, in blocks 2 to
 * 33, list one partition, uboot, at blocks 16384 to 24575. The loader on
 * the RG353V's eMMC loads U-Boot from a card only through it. A disk whose
 * block 1 holds any other GPT is not changed. Before it changes anything
 * else, it writes the disk's last MiB: zeros, and on a disk with PIE's GPT
 * the GPT's backup in its last 33 blocks. The zeros also clear what the
 * disk's earlier contents left at its end. Then it points the GPT's header
 * at that backup. An interrupted run can leave blocks 1 to 33 damaged. If
 * the last 33 blocks hold that backup, it then first rebuilds the header
 * and its entries from it. It does not when block 1 holds a valid GPT
 * header with another disk GUID.
 *
 * Before it changes the MBR, it zeroes the place of the ZFS labels L2 and
 * L3 in the grown partition: its last 512 KiB, with its size rounded down
 * to a multiple of 256 KiB. Labels that an earlier pool left there are
 * then not taken for the grown pool's. A partition that would grow so
 * little that this place overlaps it now is not changed. -n only says
 * what it would do.
 *
 * It exits 0 when the partition reaches the end of the disk, less its last
 * MiB, or the 2 TiB limit, as the kernel sees it. With -n it exits 0 when
 * it would grow the partition or the MBR already reaches that end, and it
 * does not ask the kernel. It exits 1 when it leaves the partition as it
 * is, because the disk is not one it changes or the partition would grow
 * too little. It exits 2 on a usage error. It exits 3 when writing the MBR
 * or the GPT's header failed and the original could not be written back.
 * It exits 4 when the disk cannot be closed after the MBR is written. It
 * also exits 4 when the kernel's slice is not yet the size the MBR gives,
 * or the slice's size cannot be read. The kernel then takes the new size
 * at the next boot. It exits 5 when memory runs out, or when reading or
 * writing the disk failed and the MBR is as it was, so that it can be
 * tried again.
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

#define TAIL 2048
#define GPT_BLOCKS 33
#define ENTRIES (128 * 128)

static const unsigned char disk_guid[16] = {
	0xa7, 0x35, 0xca, 0x9a, 0x48, 0x0f, 0xbf, 0x51, 0x85, 0xe1, 0xce, 0x97, 0xd9, 0x28, 0x32, 0x84,
};
static const unsigned char uboot_type[16] = {
	0x00, 0x00, 0x0b, 0xa6, 0x00, 0x00, 0x7e, 0x4c, 0x80, 0x00, 0x01, 0x5e, 0x00, 0x00, 0x4d, 0xb7,
};
static const unsigned char uboot_guid[16] = {
	0x55, 0x0b, 0x0d, 0x7d, 0x81, 0x3a, 0xa3, 0x51, 0x8d, 0x9a, 0xf5, 0x87, 0x9d, 0xce, 0xd4, 0xce,
};
static const unsigned char uboot_name[10] = { 'u', 0, 'b', 0, 'o', 0, 'o', 0, 't', 0 };

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

static uint64_t
get64(const unsigned char *p)
{
	return get32(p) | (uint64_t)get32(p + 4) << 32;
}

static void
put64(unsigned char *p, uint64_t v)
{
	put32(p, (uint32_t)v);
	put32(p + 4, (uint32_t)(v >> 32));
}

static uint32_t
crc32(const unsigned char *p, size_t n)
{
	uint32_t c = 0xffffffff;
	while (n--) {
		c ^= *p++;
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320 & -(c & 1));
	}
	return ~c;
}

static void
seal(unsigned char *h)
{
	put32(h + 16, 0);
	put32(h + 16, crc32(h, 92));
}

static int
gpt_header(const unsigned char *h)
{
	unsigned char check[512];
	uint32_t n = get32(h + 12);
	if (memcmp(h, "EFI PART", 8) != 0 || n < 92 || n > sizeof(check))
		return 0;
	memcpy(check, h, n);
	put32(check + 16, 0);
	return crc32(check, n) == get32(h + 16);
}

static int
pie_header(const unsigned char *h, const unsigned char *e, uint64_t cur, uint64_t alt, uint64_t ent, uint64_t last)
{
	if (!gpt_header(h) || get32(h + 8) != 0x10000 || get32(h + 12) != 92 || get32(h + 20) != 0 ||
	    get64(h + 24) != cur || get64(h + 32) != alt || get64(h + 40) != 34 || get64(h + 48) != last ||
	    memcmp(h + 56, disk_guid, 16) != 0 || get64(h + 72) != ent || get32(h + 80) != 128 ||
	    get32(h + 84) != 128 || crc32(e, ENTRIES) != get32(h + 88))
		return 0;
	for (int i = 92; i < 512; i++)
		if (h[i] != 0)
			return 0;
	if (memcmp(e, uboot_type, 16) != 0 || memcmp(e + 16, uboot_guid, 16) != 0 || get64(e + 32) != 16384 ||
	    get64(e + 40) != 24575 || get64(e + 48) != 0 || memcmp(e + 56, uboot_name, sizeof(uboot_name)) != 0)
		return 0;
	for (int i = 56 + (int)sizeof(uboot_name); i < ENTRIES; i++)
		if (e[i] != 0)
			return 0;
	return 1;
}

static int
pie_gpt(const unsigned char *gpt, uint64_t count)
{
	uint64_t alt = get64(gpt + 32);
	return alt >= 32768 && alt < count && pie_header(gpt, gpt + 512, 1, alt, 2, alt - 33);
}

static int
pie_backup(const unsigned char *back, uint64_t count)
{
	return pie_header(back + (GPT_BLOCKS - 1) * 512, back, count - 1, 1, count - GPT_BLOCKS, count - 34);
}

static int
put(int fd, const unsigned char *buf, size_t len, uint64_t block)
{
	unsigned char *check = malloc(len);
	int ok = check != NULL && pwrite(fd, buf, len, (off_t)(block * 512)) == (ssize_t)len &&
	    ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0 && pread(fd, check, len, (off_t)(block * 512)) == (ssize_t)len &&
	    memcmp(check, buf, len) == 0;
	free(check);
	return ok ? 0 : -1;
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
		err(5, "%s", argv[1]);
	uint64_t count = 0;
	uint32_t bs = 0;
	if (ioctl(fd, DKIOCGETBLOCKCOUNT, &count) != 0 || ioctl(fd, DKIOCGETBLOCKSIZE, &bs) != 0)
		err(5, "%s: cannot read its size", argv[1]);
	if (bs != 512)
		errx(1, "%s: blocks of %u bytes, not 512", argv[1], bs);
	unsigned char mbr[512];
	ssize_t r = pread(fd, mbr, sizeof(mbr), 0);
	if (r >= 0 && r != (ssize_t)sizeof(mbr))
		errx(5, "%s: a short read of the MBR", argv[1]);
	if (r < 0)
		err(5, "%s: cannot read the MBR", argv[1]);
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
	if (count <= TAIL)
		errx(1, "%s: smaller than 1 MiB", argv[1]);
	uint64_t end = count - TAIL > UINT32_MAX ? UINT32_MAX : count - TAIL;
	if (start + size >= end) {
		printf("pie-grow-partition: %s partition %d already reaches the end\n", argv[1], idx);
		if (!dry)
			check_slice(argv[1], idx, size);
		return 0;
	}
	unsigned char gpt[GPT_BLOCKS * 512];
	r = pread(fd, gpt, sizeof(gpt), 512);
	if (r >= 0 && r != (ssize_t)sizeof(gpt))
		errx(5, "%s: a short read of blocks 1 to 33", argv[1]);
	if (r < 0)
		err(5, "%s: cannot read blocks 1 to 33", argv[1]);
	int pie = memcmp(gpt, "EFI PART", 8) == 0;
	if (!pie_gpt(gpt, count) && !(gpt_header(gpt) && memcmp(gpt + 56, disk_guid, 16) != 0)) {
		unsigned char back[GPT_BLOCKS * 512];
		r = pread(fd, back, sizeof(back), (off_t)((count - GPT_BLOCKS) * 512));
		if (r >= 0 && r != (ssize_t)sizeof(back))
			errx(5, "%s: a short read of the last 33 blocks", argv[1]);
		if (r < 0)
			err(5, "%s: cannot read the last 33 blocks", argv[1]);
		if (pie_backup(back, count)) {
			unsigned char *h = gpt;
			memcpy(gpt + 512, back, ENTRIES);
			memcpy(h, back + (GPT_BLOCKS - 1) * 512, 512);
			put64(h + 24, 1);
			put64(h + 32, count - 1);
			put64(h + 72, 2);
			seal(h);
			printf("pie-grow-partition: %s the GPT in blocks 1 to 33 is damaged; it %s from its backup\n", argv[1],
			    dry ? "would be rebuilt" : "is rebuilt");
			if (!dry && (put(fd, gpt + 512, ENTRIES, 2) != 0 || put(fd, h, 512, 1) != 0))
				errx(5, "%s: cannot rebuild the GPT's header from its backup; the MBR is not changed", argv[1]);
			pie = 1;
		}
	}
	if (pie && !pie_gpt(gpt, count))
		errx(1, "%s: block 1 holds a GPT other than PIE's", argv[1]);
	uint32_t nsize = (uint32_t)(end - start);
	uint64_t lend = start + (nsize - nsize % 512);
	uint64_t lstart = lend - 1024;
	if (nsize < 2048 || lstart < start + size) {
		printf("pie-grow-partition: %s partition %d would grow too little to clear its labels' place; not changed\n",
		    argv[1], idx);
		return 1;
	}
	printf("pie-grow-partition: %s partition %d: %llu to %u blocks\n", argv[1], idx,
	    (unsigned long long)size, nsize);
	printf("pie-grow-partition: %s blocks %llu to %llu %s zeroed first%s\n", argv[1],
	    (unsigned long long)(count - TAIL), (unsigned long long)(count - 1), dry ? "would be" : "are",
	    pie ? ", with the GPT's backup in the last 33" : "");
	if (pie)
		printf("pie-grow-partition: %s the GPT's header %s to that backup\n", argv[1],
		    dry ? "would then point" : "then points");
	printf("pie-grow-partition: %s blocks %llu to %llu %s zeroed next, for the grown partition's labels\n",
	    argv[1], (unsigned long long)lstart, (unsigned long long)lend - 1, dry ? "would be" : "are");
	if (dry)
		return 0;
	unsigned char *t = calloc(TAIL, 512);
	if (t == NULL)
		err(5, "%s", argv[1]);
	if (pie) {
		unsigned char *b = t + (TAIL - 1) * 512;
		memcpy(t + (TAIL - GPT_BLOCKS) * 512, gpt + 512, ENTRIES);
		memcpy(b, gpt, 512);
		put64(b + 24, count - 1);
		put64(b + 32, 1);
		put64(b + 48, count - 34);
		put64(b + 72, count - GPT_BLOCKS);
		seal(b);
	}
	if (put(fd, t, TAIL * 512, count - TAIL) != 0)
		errx(5, "%s: cannot write blocks %llu to %llu; the MBR is not changed", argv[1],
		    (unsigned long long)(count - TAIL), (unsigned long long)(count - 1));
	free(t);
	if (pie) {
		unsigned char h[512];
		memcpy(h, gpt, sizeof(h));
		put64(h + 32, count - 1);
		put64(h + 48, count - 34);
		seal(h);
		if (memcmp(h, gpt, sizeof(h)) != 0 && put(fd, h, sizeof(h), 1) != 0) {
			warnx("%s: cannot write the GPT's header", argv[1]);
			if (put(fd, gpt, 512, 1) == 0)
				errx(5, "%s: the GPT's header is as it was; the MBR is not changed", argv[1]);
			errx(3, "%s: the GPT's header may be damaged; the MBR is not changed", argv[1]);
		}
	}
	unsigned char *z = calloc(1024, 512);
	if (z == NULL)
		err(5, "%s", argv[1]);
	ssize_t w = pwrite(fd, z, 1024 * 512, (off_t)(lstart * 512));
	if (w >= 0 && w != 1024 * 512)
		errx(5, "%s: a short write zeroing blocks %llu to %llu; the MBR is not changed", argv[1],
		    (unsigned long long)lstart, (unsigned long long)lend - 1);
	if (w < 0 || ioctl(fd, DKIOCSYNCHRONIZECACHE) != 0)
		err(5, "%s: cannot zero blocks %llu to %llu; the MBR is not changed", argv[1],
		    (unsigned long long)lstart, (unsigned long long)lend - 1);
	free(z);
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
			errx(5, "%s: the original MBR is back", argv[1]);
		errx(3, "%s: the MBR may be damaged", argv[1]);
	}
	if (close(fd) != 0)
		err(4, "%s: close", argv[1]);
	check_slice(argv[1], idx, nsize);
	return 0;
}
