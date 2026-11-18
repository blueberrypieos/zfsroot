/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: pie-dpkg-lock DIR ... -- COMMAND [ARGUMENT ...]
 *
 * Runs COMMAND holding the locks of each package database DIR,
 * DIR/lock-frontend and DIR/lock, as apt and dpkg take them. If apt or
 * dpkg holds one, it runs nothing and exits 75. A database on a
 * read-only file system is skipped: nothing can hold its locks.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
lock_file(const char *dir, const char *name)
{
	char path[1024];
	if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) {
		fprintf(stderr, "pie-dpkg-lock: %s: the name is too long\n", dir);
		return 1;
	}
	int fd = open(path, O_RDWR | O_CREAT, 0640);
	if (fd < 0) {
		if (errno == EROFS) {
			return 0;
		}
		fprintf(stderr, "pie-dpkg-lock: %s: %s\n", path, strerror(errno));
		return 1;
	}
	struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
	if (fcntl(fd, F_SETLK, &fl) != 0) {
		if (errno == EAGAIN || errno == EACCES) {
			fprintf(stderr, "pie-dpkg-lock: apt or dpkg holds %s; try again when it ends\n", path);
			return 75;
		}
		fprintf(stderr, "pie-dpkg-lock: %s: %s\n", path, strerror(errno));
		return 1;
	}
	return 0;
}

int
main(int argc, char *argv[])
{
	int i;
	for (i = 1; i < argc && strcmp(argv[i], "--") != 0; i++) {
	}
	if (i == 1 || i >= argc - 1) {
		fprintf(stderr, "usage: pie-dpkg-lock DIR ... -- COMMAND [ARGUMENT ...]\n");
		return 2;
	}
	for (int d = 1; d < i; d++) {
		int rc = lock_file(argv[d], "lock-frontend");
		if (rc == 0) {
			rc = lock_file(argv[d], "lock");
		}
		if (rc != 0) {
			return rc;
		}
	}
	execvp(argv[i + 1], argv + i + 1);
	fprintf(stderr, "pie-dpkg-lock: %s: %s\n", argv[i + 1], strerror(errno));
	return 127;
}
