#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# usage: sh tests/id-dispatch.sh HELPER RECORDER
set -eu
helper=$1
recorder=$2
work=$(mktemp -d "${TMPDIR:-/tmp}/pie-id-dispatch.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$4" >> "$PIE_TEST_LOG"' > "$recorder"
mkdir "$work/root"
: > "$work/log"
cat > "$work/overrides" <<'END'
#2147483647 #0 0711 /uid-max
#0 #2147483647 0711 /gid-max
#2147483648 #0 0711 /uid-over
#0 #2147483648 0711 /gid-over
#4294967295 #0 0711 /uid-reserved
#0 #4294967295 0711 /gid-reserved
#0 #0 0750 /plain-override
END
printf '%s\n' /uid-max /gid-max /uid-over /gid-over /uid-reserved /gid-reserved /plain-override /no-override |
	PIE_TEST_LOG=$work/log "$helper" "$work/root" "$work/overrides" id-dispatch > /dev/null 2>&1 || :
printf '%s\n' /gid-over /gid-reserved /uid-over /uid-reserved > "$work/expected"
LC_ALL=C sort "$work/log" > "$work/got"
if ! cmp -s "$work/expected" "$work/got"; then
	echo "id-dispatch: the shell path got other directories than expected" >&2
	diff -u "$work/expected" "$work/got" >&2 || :
	exit 1
fi
echo "id-dispatch: IDs up to 2147483647, a plain override and no override stay native; 4 larger IDs took the shell path"
