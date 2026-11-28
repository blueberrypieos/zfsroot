#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# usage: sh tests/data-setup.sh [SOURCE]
set -eu
source=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
work=$(mktemp -d "${TMPDIR:-/tmp}/pie-data-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
hash=00000000000000000000000000000000
count=0
{
    printf '%s\n' 'ADMIN=$1' 'DATA_PATHS="/private/var /private/tmp /Users /Volumes /cores /usr/local"' 'overrides=$ADMIN/statoverride'
    awk '
        /^pat=\$/ { active = 1 }
        /^} \| LC_ALL=C sort -u \| / {
            print "} | LC_ALL=C sort -u"
            exit
        }
        active { print }
    ' "$source/libexec/pie-data-setup"
} > "$work/current.sh"
grep -q '^pat=' "$work/current.sh"

fixture() {
    admin=$work/$1
    mkdir -p "$admin/info"
}

compare() {
    if sh "$source/tests/legacy-data-producer.sh" "$admin" > "$work/legacy.out" 2> "$work/legacy.err"; then before=0; else before=$?; fi
    if sh "$work/current.sh" "$admin" > "$work/current.out" 2> "$work/current.err"; then after=0; else after=$?; fi
    if [ "$before" != "$after" ] || ! cmp -s "$work/legacy.out" "$work/current.out"; then
        printf '%s\n' "data-producer: mismatch in ${admin##*/}" >&2
        diff -u "$work/legacy.out" "$work/current.out" >&2 || :
        exit 1
    fi
    count=$((count + 1))
}

fixture missing-sums
printf '%s\n' /private/var/a /private/var/a/file /usr/share/ignored > "$admin/info/a.list"
compare
printf '%s\n' /private/var/a /private/var/a/file > "$work/expected"
cmp "$work/expected" "$work/current.out"

fixture empty-sums
printf '%s\n' /private/tmp/a /private/tmp/a/file > "$admin/info/a.list"
: > "$admin/info/a.md5sums"
compare

fixture package-scope
printf '%s\n' /private/var/shared /private/var/a > "$admin/info/a.list"
printf '%s  %s\n' "$hash" private/var/shared > "$admin/info/a.md5sums"
printf '%s\n' /private/var/shared > "$admin/info/b.list"
compare
printf '%s\n' /private/var/a /private/var/shared > "$work/expected"
cmp "$work/expected" "$work/current.out"

fixture duplicates
printf '%s\n' /private/var/a /private/var/a /private/tmp/a > "$admin/info/a.list"
printf '%s\n' /private/var/a /private/tmp/a > "$admin/info/b.list"
compare

fixture path-text
printf '%s\n' '/private/var/with space' '/private/var/with\backslash' "/private/var/with'quote" > "$admin/info/a.list"
printf '/private/var/with\ttab\n' >> "$admin/info/a.list"
printf '%s  %s\n' "$hash" 'private/var/with space' > "$admin/info/a.md5sums"
compare

fixture prefixes
printf '%s\n' /Users/a /Volumes/a /cores/a /usr/local/a /etc/no /var/no /private/variety/no > "$admin/info/a.list"
compare

fixture overrides
printf '%s\n' /private/var/a > "$admin/info/a.list"
printf '%s\n' 'root wheel 1777 /private/tmp' 'root wheel 0755 /Users' 'root wheel 0700 /private/var/a' > "$admin/statoverride"
compare

fixture no-lists
printf '%s\n' 'root wheel 1777 /private/tmp' > "$admin/statoverride"
compare
printf '%s\n' /private/tmp > "$work/expected"
cmp "$work/expected" "$work/current.out"

fixture checksum-octal-escape
printf '%s\n' '/private/var/escaped\141file' > "$admin/info/a.list"
printf '%s  %s\n' "$hash" private/var/escapedafile > "$admin/info/a.md5sums"
compare

fixture checksum-double-backslash
printf '%s\n' '/private/var/with\\slash' > "$admin/info/a.list"
printf '%s  %s\n' "$hash" 'private/var/with\slash' > "$admin/info/a.md5sums"
compare

fixture trailing-space
printf '/private/var/trailing  \n' > "$admin/info/a.list"
compare

fixture trailing-tab
printf '/private/var/trailing\t\n' > "$admin/info/a.list"
compare

fixture trailing-space-checksum
printf '/private/var/trailing  \n' > "$admin/info/a.list"
printf '%s  %s\n' "$hash" private/var/trailing > "$admin/info/a.md5sums"
compare

fixture no-final-newline
printf '%s' /private/var/final > "$admin/info/a.list"
compare

fixture checksum-no-final-newline
printf '%s\n' /private/var/final > "$admin/info/a.list"
printf '%s  %s' "$hash" private/var/final > "$admin/info/a.md5sums"
compare

fixture empty-list
: > "$admin/info/a.list"
compare

fixture metadata-directory
mkdir "$admin/info/a.list"
printf '%s\n' /private/var/second > "$admin/info/b.list"
compare

fixture 'metadata with spaces'
printf '%s\n' /private/var/first > "$admin/info/a.list"
compare

fixture unreadable-checksums
printf '%s\n' /private/var/control /private/var/control/file > "$admin/info/a.list"
printf '%s  %s\n' "$hash" private/var/control/file > "$admin/info/a.md5sums"
printf '%s\n' /private/var/second > "$admin/info/b.list"
chmod 000 "$admin/info/a.md5sums"
if [ ! -r "$admin/info/a.md5sums" ]; then
    compare
    printf '%s\n' /private/var/control /private/var/control/file /private/var/second > "$work/expected"
    cmp "$work/expected" "$work/current.out"
else
    printf '%s\n' 'data-producer: unreadable checksum check skipped for privileged user'
fi

fixture unreadable-list
printf '%s\n' /private/var/first > "$admin/info/a.list"
printf '%s\n' /private/var/second > "$admin/info/b.list"
chmod 000 "$admin/info/a.list"
if [ ! -r "$admin/info/a.list" ]; then
    compare
    printf '%s\n' /private/var/second > "$work/expected"
    cmp "$work/expected" "$work/current.out"
else
    printf '%s\n' 'data-producer: unreadable list check skipped for privileged user'
fi

if [ "${PIE_TEST_LARGE:-0}" = 1 ]; then
    fixture large
    padding=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    i=0
    while [ "$i" -lt 10000 ]; do
        printf '%s\n' /private/var/large > "$admin/info/$padding$i.list"
        i=$((i + 1))
    done
    bytes=$(printf '%s\n' "$admin"/info/*.list | wc -c)
    [ "$bytes" -gt 2097152 ]
    sh "$work/current.sh" "$admin" > "$work/current.out"
    printf '%s\n' /private/var/large > "$work/expected"
    cmp "$work/expected" "$work/current.out"
    printf 'data-producer: streamed %s metadata path bytes\n' "$bytes"
    count=$((count + 1))
fi
printf 'data-producer: %s cases passed\n' "$count"
