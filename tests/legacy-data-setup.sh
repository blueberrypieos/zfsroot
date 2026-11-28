#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# usage: pie-data-setup [-r DIR]
#
# Makes the directories that installed packages list under the data paths
# (/private/var, /private/tmp, /Users, /Volumes, /cores, /usr/local),
# which dpkg leaves out on a ZFS root, in the data mounted under DIR (/ by
# default). A directory takes its mode and owner from dpkg-statoverride,
# which also sets them on a directory that exists, or else 0755
# root:wheel. /private/var/lib/dpkg is made a link to the package database
# in the root. Then each program in /usr/lib/blueberry-pie-os/data.d runs
# with DIR as its argument. It exits nonzero if any of this fails. dpkg
# runs it after every run; with DPKG_ROOT set (dpkg --root), it does
# nothing.

. /usr/libexec/pie-zfsroot.sh

[ -z "${DPKG_ROOT:-}" ] || exit 0
dir=
case ${1:-} in
-r) dir=${2%/} ;;
"") ;;
*) echo "usage: ${0##*/} [-r DIR]" >&2; exit 2 ;;
esac

rc=0
overrides=$ADMIN/statoverride
link=$dir/private/var/lib/dpkg
target=../../../usr/lib/blueberry-pie-os/dpkg
if [ -L "$link" ] && [ "$(readlink "$link")" != "$target" ]; then
	echo "${0##*/}: $link pointed to $(readlink "$link"); it points to the package database again" >&2
	rm "$link" || rc=1
fi
if [ ! -L "$link" ]; then
	if [ -d "$link" ] && rmdir "$link" 2>/dev/null || [ ! -e "$link" ]; then
		mkdir -p "$dir/private/var/lib" &&
			ln -s "$target" "$link" || rc=1
	else
		echo "${0##*/}: $link is not a link to the package database" >&2
		rc=1
	fi
fi

pat=$(echo "$DATA_PATHS" | sed 's/ /|/g')
{
	for list in "$ADMIN"/info/*.list; do
		[ -e "$list" ] || continue
		sums=${list%.list}.md5sums
		if [ ! -f "$list" ] || [ ! -r "$list" ] ||
			{ [ -f "$sums" ] && [ ! -r "$sums" ]; }; then
			printf 'F%s\n' "$list"
		elif [ -f "$sums" ]; then
			printf 'S%s\n' "$list"
		else
			printf 'L%s\n' "$list"
		fi
	done | awk -v pat="^($pat)/" '
		{
			list = substr($0, 2)
			if (substr($0, 1, 1) == "F") { print; next }
			for (key in files) delete files[key]
			for (key in paths) delete paths[key]
			n = 0
			fallback = 0
			while ((status = (getline line < list)) > 0) {
				if (line !~ pat) continue
				paths[++n] = line
				if (line ~ /\\/ || line ~ /[ \t]$/) fallback = 1
			}
			close(list)
			if (status < 0 || fallback) { print "F" list; next }
			if (!n) next
			if (substr($0, 1, 1) == "S") {
				sums = list
				sub(/\.list$/, ".md5sums", sums)
				while ((status = (getline line < sums)) > 0) {
					split(line, fields)
					files[fields[2]] = 1
				}
				close(sums)
				if (status < 0) { print "F" list; next }
			}
			for (i = 1; i <= n; i++)
				if (!(substr(paths[i], 2) in files)) print "P" paths[i]
		}
	' | while IFS= read -r record; do
		case $record in
		P*) printf '%s\n' "${record#?}" ;;
		F*)
			list=${record#?}
			sums=${list%.list}.md5sums
			grep -E "^($pat)/" "$list" | while read -r p; do
				if [ -f "$sums" ] && awk -v f="${p#/}" '$2 == f { found = 1 } END { exit !found }' "$sums"; then
					continue
				fi
				echo "$p"
			done ;;
		esac
	done
	[ -f "$overrides" ] && awk '{ print $4 }' "$overrides" | grep -E "^($pat)(/|$)"
} | LC_ALL=C sort -u | while read -r p; do
	case $p in
	/private/var/lib/dpkg|/private/var/lib/dpkg/*) continue ;;
	esac
	o=$(awk -v p="$p" '$4 == p { print $1, $2, $3; exit }' "$overrides" 2>/dev/null)
	if [ ! -d "$dir$p" ]; then
		if [ -e "$dir$p" ] || ! mkdir -p "$dir$p"; then
			echo "${0##*/}: cannot make $dir$p" >&2
			echo fail
			continue
		fi
		[ -n "$o" ] || { chown 0:0 "$dir$p" && chmod 0755 "$dir$p"; } || echo fail
	fi
	if [ -n "$o" ]; then
		set -- $o
		chown "${1#\#}:${2#\#}" "$dir$p" && chmod "$3" "$dir$p" || echo fail
	fi
done | grep -q fail && rc=1

for hook in /usr/lib/blueberry-pie-os/data.d/*; do
	[ -x "$hook" ] || continue
	if ! "$hook" "${dir:-/}"; then
		echo "${0##*/}: $hook failed" >&2
		rc=1
	fi
done
exit $rc
