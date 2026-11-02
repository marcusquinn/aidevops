#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Store deletions as index identities, not copies of the deleted blobs."""

import json
import os
from pathlib import Path
import re
import sys

from worktree_archive_git import git

NAME = "deletions-v1.json"
OPTIONS = ("--binary", "--full-index", "--no-ext-diff", "--no-textconv",
           "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short")


def capture(root, archive):
    records = {}
    for phase, flags, filename in (("staged", ("--cached",), "staged.patch"),
                                   ("unstaged", (), "diff.patch")):
        raw = git(root, "diff", *flags, "--raw", "--no-abbrev", "-z",
                  "--diff-filter=D", "--no-ext-diff", "--no-textconv")
        fields = raw.split(b"\0")[:-1]
        entries = []
        for header, path in zip(fields[::2], fields[1::2]):
            old_mode, _, old_oid, _, status = header.lstrip(b":").split()
            if status != b"D":
                raise ValueError("unexpected deletion status")
            entries.append([path.hex(), old_mode.decode(), old_oid.decode()])
        records[phase] = entries
        (archive / filename).write_bytes(
            git(root, "diff", *flags, *OPTIONS, "--diff-filter=d"))
    if any(records.values()):
        (archive / NAME).write_text(json.dumps(records, sort_keys=True) + "\n",
                                    encoding="ascii")


def load(archive):
    if not (archive / NAME).exists():
        return {"staged": [], "unstaged": []}
    value = json.loads((archive / NAME).read_bytes())
    if not isinstance(value, dict) or set(value) != {"staged", "unstaged"}:
        raise ValueError("invalid deletion inventory")
    for entries in value.values():
        if not isinstance(entries, list):
            raise ValueError("invalid deletion list")
        seen = set()
        for entry in entries:
            if (not isinstance(entry, list) or len(entry) != 3
                    or not all(isinstance(item, str) for item in entry)):
                raise ValueError("invalid deletion entry")
            encoded, mode, oid = entry
            raw = bytes.fromhex(encoded)
            parts = raw.split(b"/")
            if (not raw or b"\0" in raw or any(
                    part.lower() in (b"", b".", b"..", b".git") for part in parts)
                    or raw in seen or mode not in ("100644", "100755", "120000")
                    or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid)):
                raise ValueError("unsafe deletion entry")
            seen.add(raw)
    return value


def remove(root, entries, *, index_only=False, working_only=False):
    if not entries:
        return
    index = {}
    for item in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if item:
            metadata, path = item.split(b"\t", 1)
            index[path] = metadata.split()
    paths = []
    for encoded, mode, oid in entries:
        raw = bytes.fromhex(encoded)
        if index.get(raw) != [mode.encode(), oid.encode(), b"0"]:
            raise ValueError("deletion index identity mismatch")
        paths.append(raw)
    if not index_only:
        for raw in paths:
            target = root / os.fsdecode(raw)
            if target.parent.resolve(strict=True) != target.parent:
                raise ValueError("symlinked deletion parent")
            target.unlink()
    if paths and not working_only:
        # --index-info works in the bare verifier too; paths are literal bytes.
        data = b"".join(b"0 " + b"0" * len(index[path][1]) + b"\t" + path + b"\0"
                        for path in paths)
        git(root, "update-index", "-z", "--index-info", data=data)


def restore_phase(root, archive, phase):
    remove(root, load(archive)[phase], working_only=phase == "unstaged")


if __name__ == "__main__":
    command, root_arg, archive_arg, *rest = sys.argv[1:]
    root_path, archive_path = Path(root_arg).resolve(), Path(archive_arg).resolve()
    if command == "capture":
        capture(root_path, archive_path)
    elif command == "restore" and rest in (["staged"], ["unstaged"]):
        restore_phase(root_path, archive_path, rest[0])
    else:
        raise SystemExit("invalid deletion command")
