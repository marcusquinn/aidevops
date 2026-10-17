#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Count Markdown lines directly in Git objects, without checkouts or temp files."""

import os
from pathlib import Path
import shutil
import subprocess
import sys


EXCLUDED = {b".git", b"node_modules", b"vendor", b".venv", b"dist", b"build"}


def git_output(git, environment, *arguments):
    return subprocess.check_output(  # nosec B603 -- resolved Git, fixed read-only commands, argv only
        [git, *arguments], env=environment, stderr=subprocess.PIPE, timeout=30)


def markdown_blobs(tree):
    result = []
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        parts = path.split(b"/")
        if mode not in (b"100644", b"100755") or kind != b"blob":
            continue
        if not path.endswith(b".md") or parts[-1] == b"README.md":
            continue
        if EXCLUDED.intersection(parts[:-1]):
            continue
        if b"\t" in path or b"\n" in path or b"\r" in path:
            raise ValueError("Markdown path cannot be represented in the TSV report")
        result.append((path, oid))
    return sorted(result)


def count_blob(process, oid):
    process.stdin.write(oid + b"\n")
    process.stdin.flush()
    header = process.stdout.readline().split()
    if len(header) != 3 or header[:2] != [oid, b"blob"]:
        raise ValueError("Git blob unavailable")
    remaining = int(header[2])
    if remaining < 0:
        raise ValueError("invalid Git blob size")
    lines = 0
    while remaining:
        chunk = process.stdout.read(min(remaining, 65536))
        if not chunk:
            raise ValueError("truncated Git blob")
        remaining -= len(chunk)
        lines += chunk.count(b"\n")
    if process.stdout.read(1) != b"\n":
        raise ValueError("invalid Git batch separator")
    return lines


def scan(git, environment, blobs, limits):
    counts, violations = {}, []
    with subprocess.Popen(  # nosec B603 -- resolved Git with fixed cat-file argv, no filters or shell
        [git, "cat-file", "--batch"], env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ) as process:
        for path, oid in blobs:
            if oid not in counts:
                counts[oid] = count_blob(process, oid)
            limit = limits[1] if b"/" in path else limits[0]
            if counts[oid] > limit:
                violations.append(path + b"\t" + str(counts[oid]).encode())
        process.stdin.close()
        if process.wait(timeout=10):
            raise ValueError("Git batch scan failed")
    return violations


def main():
    ref, override, root_limit, nested_limit = sys.argv[1:]
    executable = shutil.which("git")
    if executable is None:
        raise ValueError("Git is required")
    git = str(Path(executable).absolute())
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    tree_id = git_output(git, environment, "rev-parse", "--verify", "--end-of-options", ref + "^{tree}").strip()
    tree = git_output(git, environment, "ls-tree", "--full-tree", "-rz", tree_id.decode("ascii"))
    limits = (int(override or root_limit), int(override or nested_limit))
    if min(limits) < 0:
        raise ValueError("line limits cannot be negative")
    violations = scan(git, environment, markdown_blobs(tree), limits)
    if violations:
        sys.stdout.buffer.write(b"\n".join(violations) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"file-size ref scan failed: {error}", file=sys.stderr)
        sys.exit(2)
