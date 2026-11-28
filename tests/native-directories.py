#!/usr/bin/python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# usage: python3 tests/native-directories.py HELPER SOURCE
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time

helper = str(Path(sys.argv[1]).resolve())
source = Path(sys.argv[2]).resolve()
env = dict(os.environ, LC_ALL="C")
cases = 0
privileged = os.getuid() == 0


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        result[str(path.relative_to(root))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
            info.st_uid, info.st_gid,
            os.readlink(path) if path.is_symlink() else None)
    return result


with tempfile.TemporaryDirectory(prefix="pie-directories-") as folder:
    base = Path(folder)
    oracle = base / "oracle.sh"
    frozen = (source / "tests/legacy-data-setup.sh").read_text()
    start = frozen.index("\tcase $p in\n", frozen.index("} | LC_ALL=C sort -u | while read -r p; do"))
    end = frozen.index("\ndone | grep -q fail && rc=1", start)
    oracle.write_text("dir=$1\noverrides=$2\nrc=0\nwhile read -r p; do\n" +
                      frozen[start:end] + "\ndone | grep -q fail && rc=1\nexit $rc\n")

    def prepare(root, setup):
        root.mkdir()
        if setup:
            setup(root)

    def compare(name, paths, overrides=b"", setup=None, mask=0o022):
        global cases
        folder = base / name
        folder.mkdir()
        database = folder / "statoverride"
        if name == "db-is-directory":
            database.mkdir()
        elif overrides is not None:
            database.write_bytes(overrides)
            if name == "unreadable-database":
                database.chmod(0o000)
        states = []
        statuses = []
        errors = []
        for variant in ("legacy", "native"):
            root = folder / variant
            prepare(root, setup)
            command = (["sh", str(oracle)] if variant == "legacy" else [helper])
            chunks = paths.splitlines(keepends=True) if variant == "legacy" else [paths]
            status = 0
            for chunk in chunks:
                result = subprocess.run(command + [str(root), str(database), "pie-data-setup"],
                                        input=chunk, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, umask=mask)
                status = max(status, result.returncode)
                if result.stdout:
                    raise AssertionError((name, variant, "unexpected stdout", result.stdout))
            states.append(snapshot(root))
            statuses.append(status)
            errors.append(result.stderr)
        assert statuses[0] == statuses[1], (name, statuses, errors, states)
        assert states[0] == states[1], (name, states)
        cases += 1

    default = b"/private/var/a/b\n/private/tmp/a\n/Users/test\n/private/var/lib/dpkg\n/private/var/lib/dpkg/skip\n"
    compare("defaults", default)
    compare("missing-database", default, None)
    compare("unreadable-database", b"/a\n", b"#0 #0 0700 /a\n")
    compare("duplicates", b"/private/var/a\n" * 3)
    compare("whitespace", b" \t/private/var/space in name \t\n/private/var/tab\there\n")
    compare("backslash", b"/private/var/back\\slash\n/private/var/back\\141\n")
    compare("unicode", "/private/var/caf\u00e9\n".encode())
    compare("unterminated", b"/private/var/yes\n/private/var/no")
    compare("parent-components", b"/private/var//a/../b/./c/\n")
    if privileged:
        compare("restrictive-mask", b"/private/var/a/b\n", mask=0o777)
    compare("empty-path", b"\n \t\n")
    compare("existing", b"/existing\n", setup=lambda root: (root / "existing").mkdir(mode=0o711))
    compare("file-conflict", b"/blocked\n/after\n", setup=lambda root: (root / "blocked").write_text("x"))
    compare("parent-file", b"/blocked/child\n/after\n", setup=lambda root: (root / "blocked").write_text("x"))

    def links(root):
        (root / "target").mkdir(mode=0o711)
        (root / "link").symlink_to("target")
        (root / "dangling").symlink_to("absent")
        (root / "cycle").symlink_to("cycle")
    compare("symlinks", b"/link\n/link/sub\n/dangling\n/cycle\n/after\n", setup=links)
    user, group = os.getuid(), os.getgid()
    prefix = f"#{user} #{group} ".encode()
    compare("numeric-overrides", b"/a\n/b\n/c\n", prefix + b"0701 /a\n" + prefix + b"1770 /b\n" + prefix + b"4770 /c\n")
    compare("first-match", b"/a\n", prefix + b"0711 /a\n" + prefix + b"0700 /a\n")
    compare("tabs-extra-fields", b"/a\n", f"#{user}\t#{group}\t0711\t/a\textra\n".encode())
    compare("override-no-newline", b"/a\n", prefix + b"0711 /a")
    compare("symbolic-mode", b"/a\n", prefix + b"u=rwx,go= /a\n")
    compare("invalid-mode", b"/a\n/after\n", prefix + b"0899 /a\n")
    compare("invalid-user", b"/a\n/after\n", b"pie-user-that-does-not-exist #0 0711 /a\n")
    compare("reserved-ids", b"/a\n/b\n/after\n", b"#4294967295 #0 0711 /a\n#0 #4294967295 0711 /b\n")
    compare("large-ids", b"/a\n/b\n/after\n", b"#2147483648 #0 0711 /a\n#0 #2147483648 0711 /b\n")
    compare("unknown-lines", b"/a\n", b"bad\rline\n" + prefix + b"0711 /a\n")
    compare("override-backslash", b"/back\\141\n", prefix + b"0711 /backa\n")
    compare("db-is-directory", b"/a\n", None, setup=lambda root: None)
    if privileged:
        compare("owners", b"/a\n/b\n", b"#123 #456 2751 /a\n#0 #0 1777 /b\n")
    else:
        def denied(root):
            (root / "no-access").mkdir(mode=0o000)
        compare("unreadable-parent", b"/no-access/child\n/after\n", setup=denied)

    def live(name, initial, replacement, operation):
        global cases
        results = []
        for variant in ("legacy", "native"):
            folder = base / (name + "-" + variant)
            folder.mkdir()
            root = folder / "root"
            root.mkdir()
            for n in (1, 2):
                (root / str(n)).mkdir(mode=0o755)
            database = folder / "statoverride"
            if initial is not None:
                database.write_bytes(initial)
            command = (["sh", str(oracle)] if variant == "legacy" else [helper])
            process = subprocess.Popen(command + [str(root), str(database), "pie-data-setup"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, env=env)
            try:
                process.stdin.write(b"/1\n/ready\n")
                process.stdin.flush()
                deadline = time.monotonic() + 10
                while not (root / "ready").exists():
                    assert process.poll() is None, (name, variant, "early exit")
                    assert time.monotonic() < deadline, (name, variant, "no progress")
                    time.sleep(0.005)
                if operation == "delete":
                    database.unlink()
                elif operation == "replace":
                    new = folder / "new"
                    new.write_bytes(replacement)
                    new.replace(database)
                else:
                    database.write_bytes(replacement)
                process.stdin.write(b"/2\n")
                process.stdin.close()
                process.stdin = None
                output, error = process.communicate(timeout=10)
                assert process.returncode == (0 if privileged else 1), (name, variant, error)
                results.append(snapshot(root))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait()
        assert results[0] == results[1], (name, results)
        assert results[1]["2"][1] == (0o755 if operation == "delete" else 0o711)
        cases += 1

    old = prefix + b"0700 /1\n" + prefix + b"0700 /2\n"
    new = prefix + b"0711 /2\n"
    live("live-atomic", old, new, "replace")
    live("live-in-place", old, new, "write")
    live("live-create", None, new, "write")
    live("live-delete", old, None, "delete")
    stream = b"/private/var/lib/dpkg/" + b"x" * 200 + b"\n"
    result = subprocess.run([helper, str(base), str(base / "no-database"), "pie-data-setup"],
                            input=stream * 12000, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    assert result.returncode == 0 and not result.stdout and not result.stderr
    cases += 1
    assert len(stream) * 12000 > 2097152

print(f"native-directories: {cases} differential cases passed; mapped-root={privileged}")
