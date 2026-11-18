/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: pie-mount [-r] DATASET DIR
 *
 * Mounts the ZFS dataset DATASET on DIR, read-only with -r, whatever its
 * mountpoint property says.
 */
#include <sys/mount.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct zfs_mount_args {
	const char *fspec;
	int mflag;
	const char *optptr;
	int optlen;
	int struct_size;
};

int
main(int argc, char *argv[])
{
	int flags = 0, c;

	while ((c = getopt(argc, argv, "r")) != -1) {
		if (c != 'r') {
			fprintf(stderr, "usage: pie-mount [-r] DATASET DIR\n");
			return 2;
		}
		flags |= MNT_RDONLY;
	}
	if (argc - optind != 2) {
		fprintf(stderr, "usage: pie-mount [-r] DATASET DIR\n");
		return 2;
	}
	struct zfs_mount_args args = { argv[optind], flags, NULL, 0, sizeof(args) };
	if (mount("zfs", argv[optind + 1], flags, &args) != 0) {
		fprintf(stderr, "pie-mount: %s on %s: %s\n", argv[optind], argv[optind + 1], strerror(errno));
		return 1;
	}
	return 0;
}
