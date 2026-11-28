#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# usage: sh tests/hfs-root.sh [SOURCE]
set -eu
source=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
source=$(CDPATH= cd -- "$source" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pie-hfs-root.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
count=0
fail() {
	echo "hfs-root: $*" >&2
	exit 1
}
pass() {
	count=$((count + 1))
}
mkdir "$work/bin"
cat > "$work/bin/mount" <<'END'
#!/bin/sh
echo "$PIE_TEST_ROOT" >> "$PIE_TEST_MOUNT_LOG"
case $PIE_TEST_ROOT in
zfs) echo "pie/root/1 on ${DPKG_ROOT:-/} (zfs, local, journaled, noatime)" ;;
zfs-dir) echo "pie/root/1 on / (zfs, local, journaled, noatime)" ;;
zfs-stage)
	echo "pie/root/1 on / (zfs, local, read-only, journaled, noatime)"
	echo "pie/root/2 on $DPKG_ROOT (zfs, local, journaled, noatime)"
	;;
hfs) echo "/dev/disk0s2 on ${DPKG_ROOT:-/} (hfs, local, journaled)" ;;
linux) echo "/dev/sda1 on / type ext4 (rw,relatime)" ;;
esac
echo "devfs on /dev (devfs, local, nobrowse)"
END
chmod 755 "$work/bin/mount"
PATH=$work/bin:$PATH
PIE_TEST_MOUNT_LOG=$work/mount.log
export PATH PIE_TEST_MOUNT_LOG
dpkgcfg=etc/dpkg/dpkg.cfg.d/pie-zfs
aptcfg=etc/apt/apt.conf.d/40pie-zfs
stagecfg=$(sed -n 's|^conf=$tmp/private/etc/apt/apt.conf.d/\(.*\)$|\1|p' "$source/sbin/pie-seal")
old=etc/dpkg/dpkg.cfg.d/pie-data

tree() {
	t=$work/$1
	mkdir -p "$t/etc/dpkg/dpkg.cfg.d" "$t/etc/apt/apt.conf.d" "$t/usr/lib/blueberry-pie-os/zfs"
	cp "$source/lib/zfs/dpkg.cfg" "$source/lib/zfs/apt.conf" "$t/usr/lib/blueberry-pie-os/zfs/"
}
oldcfg() {
	cat <<'END'
path-exclude=/private/var/*
path-exclude=/private/tmp/*
path-exclude=/Users/*
path-exclude=/Volumes/*
path-exclude=/cores/*
path-exclude=/usr/local/*
post-invoke=/usr/libexec/pie-data-setup
END
}
oldapt() {
	cat <<'END'
Dir::State::extended_states "/usr/lib/blueberry-pie-os/apt/extended_states";
DPkg::Pre-Invoke { "/usr/libexec/pie-stage pre"; };
DPkg::Post-Invoke { "/usr/libexec/pie-stage post"; };
END
}
rootapt=etc/apt/apt.conf.d/50pie-root
run() {
	PIE_TEST_ROOT=$1 DPKG_ROOT=$t sh "$source/debian/$2" $3 ${4:-}
}
same() {
	cmp -s "$source/lib/zfs/dpkg.cfg" "$t/$dpkgcfg" || fail "$1: $dpkgcfg differs from lib/zfs/dpkg.cfg"
	cmp -s "$source/lib/zfs/apt.conf" "$t/$aptcfg" || fail "$1: $aptcfg differs from lib/zfs/apt.conf"
}
absent() {
	for f in "$@"; do
		[ ! -e "$t/$f" ] || fail "$case: $f exists"
	done
}

hash=$(oldcfg | sha256sum | cut -d ' ' -f 1)
for script in preinst postinst postrm; do
	grep -q "= $hash ]" "$source/debian/$script" || fail "$script does not know the old conffile's checksum $hash"
done
hash=$(oldapt | sha256sum | cut -d ' ' -f 1)
grep -q "= $hash ]" "$source/debian/preinst" || fail "preinst does not know the old apt conffile's checksum $hash"
pass

[ -n "$stagecfg" ] || fail "cannot find the stage's apt file in pie-seal"
[ "$(printf '%s\n' "$stagecfg" "${aptcfg##*/}" | LC_ALL=C sort | head -n 1)" = "${aptcfg##*/}" ] ||
	fail "${aptcfg##*/} sorts after $stagecfg, so it would override the stage's extended_states"
pass

if [ ! -e /usr/libexec/pie-stage ]; then
	sed -n 's/^DPkg::[A-Za-z-]* { "\(.*\)"; };$/\1/p' "$source/etc/apt/apt.conf.d/50pie-root" > "$work/hooks"
	[ "$(wc -l < "$work/hooks")" = 2 ] || fail "cannot read the two apt hooks"
	while IFS= read -r hook; do
		sh -c "$hook" || fail "the apt hook '$hook' fails without pie-stage"
	done < "$work/hooks"
	pass
fi

for root in hfs linux; do
	case=fresh-$root
	tree $case
	run $root preinst install
	absent $dpkgcfg $aptcfg
	run $root postinst configure
	absent $dpkgcfg $aptcfg
	pass
	case=upgrade-$root
	tree $case
	oldcfg > "$t/$old"
	oldapt > "$t/$rootapt"
	run $root preinst upgrade 5
	absent $dpkgcfg $aptcfg $old
	cmp -s "$source/$rootapt" "$t/$rootapt" || fail "$case: preinst did not guard the old apt hooks"
	run $root postinst configure 5
	absent $dpkgcfg $aptcfg $old $old.dpkg-bak
	pass
done

case=zfs-root-plain-target
tree $case
run zfs-dir preinst install
run zfs-dir postinst configure
absent $dpkgcfg $aptcfg
pass

case=sealed-stage
tree $case
run zfs-stage preinst upgrade 5
same "$case preinst"
echo "# the stage's own" >> "$t/usr/lib/blueberry-pie-os/zfs/dpkg.cfg"
run zfs-stage postinst configure 5
cmp -s "$t/usr/lib/blueberry-pie-os/zfs/dpkg.cfg" "$t/$dpkgcfg" || fail "$case postinst: $dpkgcfg is not the stage's own copy"
pass

case=fresh-zfs
tree $case
run zfs preinst install
same "$case preinst"
run zfs postinst configure
same "$case postinst"
pass

case=upgrade-zfs
tree $case
oldcfg > "$t/$old"
oldapt > "$t/$rootapt"
run zfs preinst upgrade 5
same "$case preinst"
absent $old
cmp -s "$source/$rootapt" "$t/$rootapt" || fail "$case: preinst did not guard the old apt hooks"
run zfs postinst configure 5
same "$case postinst"
absent $old $old.dpkg-bak
pass

case=upgrade-zfs-edited
tree $case
{ oldcfg; echo "# local"; } > "$t/$old"
{ oldapt; echo "# local"; } > "$t/$rootapt"
run zfs preinst upgrade 5
[ -f "$t/$old" ] || fail "$case: preinst removed the edited $old"
grep -q "^# local$" "$t/$rootapt" || fail "$case: preinst replaced the edited $rootapt"
run zfs postinst configure 5
absent $old
cmp -s "$t/$old.dpkg-bak" - <<END || fail "$case: the edited $old was not kept as $old.dpkg-bak"
$(oldcfg)
# local
END
pass

for action in remove purge; do
	case=$action
	tree $case
	run zfs preinst install
	run zfs postinst configure
	run zfs postrm $action
	absent $dpkgcfg $aptcfg
	pass
done

case=purge-edited
tree $case
{ oldcfg; echo "# local"; } > "$t/$old"
run zfs preinst upgrade 5
run zfs postinst configure 5
[ -f "$t/$old.dpkg-bak" ] || fail "$case: no $old.dpkg-bak after the upgrade"
run zfs postrm remove
run zfs postrm purge
absent $dpkgcfg $aptcfg $old $old.dpkg-bak
pass

for root in zfs hfs; do
	case=unconfigured-upgrade-removed-$root
	tree $case
	oldcfg > "$t/$old"
	run $root preinst upgrade 5
	run $root postrm remove
	absent $dpkgcfg $aptcfg $old $old.dpkg-bak
	pass
done

case=config-writer
tree $case
config() {
	sh -c '. "$1"; zfs_config "$2"' sh "$source/libexec/pie-zfsroot.sh" "$1"
}
echo "# the stage's own" >> "$t/usr/lib/blueberry-pie-os/zfs/dpkg.cfg"
config "$t" || fail "$case: zfs_config failed"
cmp -s "$t/usr/lib/blueberry-pie-os/zfs/dpkg.cfg" "$t/$dpkgcfg" || fail "$case: $dpkgcfg is not the target's own copy"
cmp -s "$source/lib/zfs/apt.conf" "$t/$aptcfg" || fail "$case: $aptcfg is not the target's own copy"
touch -d '2000-01-01' "$t/$dpkgcfg"
config "$t"
[ "$(find "$t/$dpkgcfg" -newermt '2001-01-01')" = "" ] || fail "$case: zfs_config rewrote a file that was already right"
echo changed > "$t/$aptcfg"
config "$t"
cmp -s "$source/lib/zfs/apt.conf" "$t/$aptcfg" || fail "$case: zfs_config did not repair $aptcfg"
mkdir -p "$t/removed/etc"
config "$t/removed"
[ ! -e "$t/removed/$dpkgcfg" ] && [ ! -e "$t/removed/$aptcfg" ] || fail "$case: zfs_config wrote into a root without pie-zfsroot"
pass

case=commands-hfs
mkdir -p "$work/$case"
printf '%s\n' '#!/bin/sh' 'echo 0' > "$work/bin/id"
printf '%s\n' '#!/bin/sh' 'echo "lockf called" >&2' 'exit 1' > "$work/bin/lockf"
chmod 755 "$work/bin/id" "$work/bin/lockf"
sed "s|^PATH=/usr/sbin:/usr/bin:/sbin:/bin$|PATH=$work/bin:/usr/sbin:/usr/bin:/sbin:/bin|" "$source/libexec/pie-zfsroot.sh" > "$work/$case/pie-zfsroot.sh"
for cmd in libexec/pie-stage sbin/pie-seal; do
	sed "s|^\. /usr/libexec/pie-zfsroot.sh$|. $work/$case/pie-zfsroot.sh|" "$source/$cmd" > "$work/$case/${cmd##*/}"
done
PIE_TEST_ROOT=hfs sh "$work/$case/pie-stage" pre || fail "$case: pie-stage pre failed on HFS"
PIE_TEST_ROOT=hfs sh "$work/$case/pie-stage" post || fail "$case: pie-stage post failed on HFS"
ln -s pie-seal "$work/$case/pie-unseal"
for args in "pie-stage commit" "pie-stage run true" "pie-seal" "pie-unseal"; do
	set -- $args
	if PIE_TEST_ROOT=hfs sh "$work/$case/$1" ${2:-} ${3:-} 2> "$work/$case/err"; then
		fail "$case: $args succeeded on HFS"
	fi
	grep -q "the root is not a ZFS dataset" "$work/$case/err" || fail "$case: $args said: $(cat "$work/$case/err")"
done
pass

case=data-setup-hfs
mkdir -p "$work/$case"
sed "s|^PATH=/usr/sbin:/usr/bin:/sbin:/bin$|PATH=$work/bin:/usr/sbin:/usr/bin:/sbin:/bin|" "$source/libexec/pie-zfsroot.sh" > "$work/$case/pie-zfsroot.sh"
grep -q "^PATH=$work/bin:" "$work/$case/pie-zfsroot.sh" || fail "$case: cannot put the mount stub first in the library's PATH"
sed "s|^\. /usr/libexec/pie-zfsroot.sh$|. $work/$case/pie-zfsroot.sh|" "$source/libexec/pie-data-setup" > "$work/$case/pie-data-setup"
grep -q "^\. $work/$case/pie-zfsroot.sh$" "$work/$case/pie-data-setup" || fail "$case: cannot point pie-data-setup at the test library"
for root in hfs linux zfs; do
	mkdir "$work/$case/$root"
	: > "$PIE_TEST_MOUNT_LOG"
	status=0
	PIE_TEST_ROOT=$root sh "$work/$case/pie-data-setup" -r "$work/$case/$root" > /dev/null 2>&1 || status=$?
	grep -qx "$root" "$PIE_TEST_MOUNT_LOG" || fail "$case: the mount stub was not asked on $root"
	if [ $root = zfs ]; then
		[ -L "$work/$case/$root/private/var/lib/dpkg" ] || fail "$case: pie-data-setup did nothing on a ZFS root"
	else
		[ $status = 0 ] || fail "$case: exit status $status on $root"
		[ -z "$(ls -A "$work/$case/$root")" ] || fail "$case: pie-data-setup wrote into the data directory on $root"
	fi
done
pass

echo "hfs-root: $count cases passed"
