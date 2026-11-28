# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# pie-zfsroot.sh: shell functions for the ZFS root commands, sourced by
# them from /usr/libexec.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

ADMIN=/usr/lib/blueberry-pie-os/dpkg
UPDATE=/System/Volumes/Update
TARGET=/var/run/pie-softreboot
LOCK=/var/run/pie-zfsroot.lock
DATA_PATHS="/private/var /private/tmp /Users /Volumes /cores /usr/local"

die() {
	echo "${0##*/}: $*" >&2
	exit 1
}

need_root() {
	[ "$(id -u)" = 0 ] || die "must be run as root"
}

serialize() {
	if [ -z "${PIE_ZFSROOT_LOCKED:-}" ]; then
		PIE_ZFSROOT_LOCKED=1
		export PIE_ZFSROOT_LOCKED
		exec lockf -k "$LOCK" "$@"
	fi
}

exclusive() {
	serialize "$@"
	if [ -z "${PIE_ZFSROOT_DPKG:-}" ]; then
		PIE_ZFSROOT_DPKG=1
		export PIE_ZFSROOT_DPKG
		set -- -- "$@"
		[ -d "$UPDATE$ADMIN" ] && set -- "$UPDATE$ADMIN" "$@"
		exec /usr/libexec/pie-dpkg-lock "$ADMIN" "$@"
	fi
}

root_ds() {
	mount | awk '$2 == "on" && $3 == "/" && $4 == "(zfs," { print $1; exit }'
}

prop() {
	zfs get -H -o value "$1" "$2" 2>/dev/null
}

pprop() {
	v=$(zpool get -H -o value "$1" "$2" 2>/dev/null)
	[ "$v" = - ] && v=
	echo "$v"
}

exists() {
	zfs list -H -o name "$1" > /dev/null 2>&1
}

sealed() {
	[ "$(prop pie:sealed "$1")" = on ]
}

stamp() {
	date -u +%Y%m%dT%H%M%SZ
}

snapname() {
	b=$(bootid)
	echo "$1-$(stamp)${b:+-$b}"
}

rootset() {
	if [ "$(prop pie:dirty "$1")" = on ]; then
		echo dirty
	else
		prop pie:kernelset "$1"
	fi
}

record() {
	zfs set pie:kernelset="$2" "$1" && zfs inherit pie:dirty "$1"
}

changing() {
	g=$(prop guid "$1") && b=$(bootid) && t=$(stamp) || return 1
	case $g in ""|-|*[!0-9]*) return 1 ;; esac
	[ -n "$b" ] && [ -n "$t" ] || return 1
	echo "changing-$g-$b-$$-$t"
}

next_root() {
	n=$(zfs list -H -o name -d 1 -t filesystem "$1/root" 2>/dev/null |
		sed -n "s|^$1/root/\([0-9][0-9]*\)$|\1|p" | sort -n | tail -n 1)
	echo "$1/root/$(( ${n:-0} + 1 ))"
}

kernelset() {
	(
		cd "$1" && [ -d usr/lib/blueberry-pie-os/boot ] && [ -d System/Library/Extensions ] || exit 1
		dirs="usr/lib/blueberry-pie-os/boot System/Library/Extensions"
		[ -d usr/lib/blueberry-pie-os/kexts.early ] && dirs="$dirs usr/lib/blueberry-pie-os/kexts.early"
		files=$(find $dirs -type f) || exit 1
		[ -n "$files" ] || exit 1
		sums=$(echo "$files" | LC_ALL=C sort | xargs sha256sum) || exit 1
		h=$(echo "$sums" | sha256sum) || exit 1
		h=${h%% *}
		[ ${#h} = 64 ] || exit 1
		echo "$h"
	)
}

bootid() {
	sysctl -n kern.bootsessionuuid 2>/dev/null
}

valid() {
	[ ${#1} = 64 ] && case $1 in *[!0-9a-f]*) false ;; esac
}

coldkernel() {
	bt=$(bootid)
	[ -n "$bt" ] && [ "$(pprop pie:coldboot "$1")" = "$bt" ] || return 0
	k=$(pprop pie:coldkernel "$1")
	! valid "$k" || echo "$k"
}

boot_from() {
	zpool set pie:bootkernel=pending "$1" &&
		/usr/libexec/blueberry-pie-os-update-boot --from "$2/usr/lib/blueberry-pie-os/boot" &&
		zpool set pie:bootkernel="$3" "$1"
}

mount_at() {
	mkdir -p "$2" 2>/dev/null
	if [ "${3:-}" = ro ]; then
		/usr/libexec/pie-mount -r "$1" "$2"
	else
		/usr/libexec/pie-mount "$1" "$2"
	fi
}

mount_data() {
	list=$(zfs list -H -o name,mountpoint -r -t filesystem "$1" 2>/dev/null) || return 1
	[ -n "$list" ] || return 1
	if ! echo "$list" | awk -v d="$1" 'NR == 1 { exit !($1 == d && $2 == "/private/var") }'; then
		echo "${0##*/}: $1's mountpoint is not /private/var" >&2
		return 1
	fi
	echo "$list" | while read -r ds mp; do
		case $mp in
		/*) mount_at "$ds" "$2$mp" || exit 1 ;;
		esac
	done
}

make_root() {
	zfs clone -o mountpoint=legacy -o canmount=noauto -o readonly=off \
		-o pie:sealed="$3" -o pie:parent="${1%@*}" "$1" "$2" || return 1
	t=$(mktemp -d /private/var/tmp/pie-root.XXXXXX) || { zfs destroy "$2"; return 1; }
	if mount_at "$2" "$t" ro; then
		ks=$(kernelset "$t")
		umount "$t"
	else
		ks=
	fi
	rmdir "$t"
	if [ -z "$ks" ] || ! zfs set pie:kernelset="$ks" "$2"; then
		zfs destroy "$2"
		return 1
	fi
}
