#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
ADMIN=$1
DATA_PATHS="/private/var /private/tmp /Users /Volumes /cores /usr/local"
overrides=$ADMIN/statoverride
pat=$(echo "$DATA_PATHS" | sed 's/ /|/g')
{
	for list in "$ADMIN"/info/*.list; do
		[ -e "$list" ] || continue
		sums=${list%.list}.md5sums
		grep -E "^($pat)/" "$list" | while read -r p; do
			if [ -f "$sums" ] && awk -v f="${p#/}" '$2 == f { found = 1 } END { exit !found }' "$sums"; then
				continue
			fi
			echo "$p"
		done
	done
	[ -f "$overrides" ] && awk '{ print $4 }' "$overrides" | grep -E "^($pat)(/|$)"
} | LC_ALL=C sort -u
