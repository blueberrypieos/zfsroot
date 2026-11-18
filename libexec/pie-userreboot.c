/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: pie-userreboot
 *
 * Asks init for a soft reboot: reboot3() with RB2_USERREBOOT.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define RB2_USERREBOOT 0x2000000000000000ULL

int reboot3(uint64_t howto, ...);

int
main(void)
{
	int r = reboot3(RB2_USERREBOOT);
	if (r != 0) {
		fprintf(stderr, "pie-userreboot: %s\n", strerror(r));
		return 1;
	}
	return 0;
}
