#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# usage: sh tests/data-actions.sh SOURCE
set -eu
source=$1
if [ "$(id -u)" != 0 ]; then
    printf '%s\n' 'data-actions: owner checks require a mapped root namespace'
    exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/pie-data-actions.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
for variant in current legacy; do
    if [ "$variant" = current ]; then input=$source/libexec/pie-data-setup; else input=$source/tests/legacy-data-setup.sh; fi
    sed 's@^\. /usr/libexec/pie-zfsroot.sh$@. "$PIE_TEST_LIB"@;s@for hook in /usr/lib/blueberry-pie-os/data.d/\*; do@for hook in "$PIE_TEST_HOOKS"/*; do@;s@/usr/libexec/pie-data-directories @"$PIE_TEST_DIRECTORIES" @' "$input" > "$work/$variant.sh"
done
export PIE_TEST_DIRECTORIES=${PIE_TEST_DIRECTORIES:-/usr/libexec/pie-data-directories}
cat > "$work/library.sh" <<'EOF'
ADMIN=$PIE_TEST_ADMIN
DATA_PATHS="/private/var /private/tmp /Users /Volumes /cores /usr/local"
root_ds() {
    echo pie/root/1
}
EOF
export PIE_TEST_LIB=$work/library.sh
export PIE_TEST_ADMIN=$work/admin
export PIE_TEST_HOOKS=$work/hooks
mkdir -p "$PIE_TEST_ADMIN/info" "$PIE_TEST_HOOKS"
printf '%s\n' /private/var/app /private/var/app/file /private/var/owned /private/var/lib/dpkg/ignored /private/tmp/app /usr/local/pie /Users/admin > "$PIE_TEST_ADMIN/info/a.list"
printf '%s\n' '00000000000000000000000000000000  private/var/app/file' > "$PIE_TEST_ADMIN/info/a.md5sums"
printf '%s\n' '#123 #456 0710 /private/var/owned' '#0 #0 1777 /private/tmp' > "$PIE_TEST_ADMIN/statoverride"
cat > "$PIE_TEST_HOOKS/check" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$PIE_TEST_HOOK_LOG"
exit "${PIE_TEST_HOOK_FAIL:-0}"
EOF
chmod 755 "$PIE_TEST_HOOKS/check"
os=$(uname -s)
metadata() {
    if [ "$os" = Darwin ]; then
        values=$(stat -f '%u %g %p' "$1") || return
        set -- $values
        printf '%s:%s:%o\n' "$1" "$2" "$((0$3 & 07777))"
    else
        stat -c '%u:%g:%a' "$1"
    fi
}
manifest() {
    root=$1
    find "$root" -type d | LC_ALL=C sort | while IFS= read -r path; do
        printf '%s|%s\n' "${path#"$root"}" "$(metadata "$path")"
    done
}
run_pair() {
    expected=$1
    for variant in legacy current; do
        root=$work/$variant
        export PIE_TEST_HOOK_LOG=$work/$variant.hooks
        if sh "$work/$variant.sh" -r "$root/" > "$work/$variant.out" 2> "$work/$variant.err"; then status=0; else status=$?; fi
        [ "$status" = "$expected" ] || { cat "$work/$variant.err" >&2; exit 1; }
        [ "$(readlink "$root/private/var/lib/dpkg")" = ../../../usr/lib/blueberry-pie-os/dpkg ]
        [ ! -e "$root/private/var/app/file" ]
        [ "$(metadata "$root/private/var/owned")" = 123:456:710 ]
        [ "$(metadata "$root/private/tmp")" = 0:0:1777 ]
        [ "$(metadata "$root/Users/admin")" = 123:456:750 ]
        manifest "$root" > "$work/$variant.manifest"
        sed "s|$root|ROOT|g" "$PIE_TEST_HOOK_LOG" > "$work/$variant.normalized-hooks"
    done
    cmp "$work/legacy.manifest" "$work/current.manifest"
    cmp "$work/legacy.normalized-hooks" "$work/current.normalized-hooks"
}
for variant in legacy current; do
    root=$work/$variant
    mkdir -p "$root/Users/admin" "$root/private/var/lib" "$root/private/var/owned"
    chown 123:456 "$root/Users/admin"
    chmod 750 "$root/Users/admin"
    chmod 777 "$root/private/var/owned"
    ln -s not-the-database "$root/private/var/lib/dpkg"
done
run_pair 0
for variant in legacy current; do
    chmod 777 "$work/$variant/private/var/owned"
    rmdir "$work/$variant/private/var/app"
done
run_pair 0
printf '%s\n' /private/var/blocked >> "$PIE_TEST_ADMIN/info/a.list"
for variant in legacy current; do
    printf '%s\n' occupied > "$work/$variant/private/var/blocked"
done
run_pair 1
sed '/blocked$/d' "$PIE_TEST_ADMIN/info/a.list" > "$work/list.new"
mv "$work/list.new" "$PIE_TEST_ADMIN/info/a.list"
export PIE_TEST_HOOK_FAIL=7
run_pair 1
printf '%s\n' 'data-actions: directory, owner, mode, symlink, repeat, conflict and hook checks passed'
