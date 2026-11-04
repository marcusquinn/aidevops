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
           "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short",
           "--find-renames", "-O" + os.devnull)


def capture(root, archive):
    """Capture patches and identity-only deletion lists without refreshing index."""
    records = {}
    for phase, flags, filename in (("staged", ("--cached",), "staged.patch"),
                                   ("unstaged", (), "diff.patch")):
        raw = git(root, "diff", *flags, "--raw", "--no-abbrev", "-z",
                  "--diff-filter=D", "--no-ext-diff", "--no-textconv",
                  "--find-renames", "-O" + os.devnull)
        fields = raw.split(b"\0")[:-1]
        entries = []
        # macOS system Python 3.9 has no zip(strict=...). Keep the same
        # fail-closed pairing check, including when there are no deletions.
        if len(fields) % 2:
            raise ValueError("incomplete deletion record")
        for offset in range(0, len(fields), 2):
            header, path = fields[offset:offset + 2]
            old_mode, _, old_oid, _, status = header.lstrip(b":").split()
            if status != b"D":
                raise ValueError("unexpected deletion status")
            entry = [path.hex(), old_mode.decode(), old_oid.decode()]
            deletion_path(entry)  # Refuse unsupported modes before publishing a payload.
            entries.append(entry)
        records[phase] = entries
        (archive / filename).write_bytes(
            git(root, "diff", *flags, *OPTIONS, "--diff-filter=d"))
    if any(records.values()):
        (archive / NAME).write_text(json.dumps(records, sort_keys=True) + "\n",
                                    encoding="ascii")


def deletion_path(entry):
    """Validate one serialized identity and return its literal pathname bytes."""
    if not isinstance(entry, list) or len(entry) != 3:
        raise ValueError("invalid deletion entry")
    if not all(isinstance(item, str) for item in entry):
        raise ValueError("invalid deletion entry")
    encoded, mode, oid = entry
    if mode not in ("100644", "100755", "120000"):
        raise ValueError("unsafe deletion mode")
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid):
        raise ValueError("unsafe deletion object ID")
    raw = bytes.fromhex(encoded)
    validate_path(raw)
    return raw


def validate_path(raw):
    """Refuse traversal, administration paths and malformed filename bytes."""
    if not raw or b"\0" in raw:
        raise ValueError("unsafe deletion path")
    forbidden = (b"", b".", b"..", b".git")
    if any(part.lower() in forbidden for part in raw.split(b"/")):
        raise ValueError("unsafe deletion path")


def validate_entries(entries):
    """Validate each phase independently, including duplicate decoded paths."""
    if not isinstance(entries, list):
        raise ValueError("invalid deletion list")
    seen = set()
    for entry in entries:
        raw = deletion_path(entry)
        if raw in seen:
            raise ValueError("duplicate deletion path")
        seen.add(raw)


def load(archive):
    """Load validated compact metadata, or empty phases for legacy archives."""
    if not (archive / NAME).exists():
        return {"staged": [], "unstaged": []}
    value = json.loads((archive / NAME).read_bytes())
    if not isinstance(value, dict) or set(value) != {"staged", "unstaged"}:
        raise ValueError("invalid deletion inventory")
    for entries in value.values():
        validate_entries(entries)
    return value


def index_entries(root):
    """Read mode, object ID and stage without interpreting pathspec syntax."""
    index = {}
    for item in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if item:
            metadata, path = item.split(b"\t", 1)
            index[path] = metadata.split()
    return index


def remove_working_paths(root, paths):
    """Unlink only selected files beneath non-symlinked restored parents."""
    for raw in paths:
        target = root / os.fsdecode(raw)
        if target.parent.resolve(strict=True) != target.parent:
            raise ValueError("symlinked deletion parent")
        target.unlink()


def remove(root, entries, *, index_only=False, working_only=False):
    """Check every index identity before removing any file or index entry."""
    if not entries:
        return
    index = index_entries(root)
    paths = []
    for encoded, mode, oid in entries:
        raw = bytes.fromhex(encoded)
        if index.get(raw) != [mode.encode(), oid.encode(), b"0"]:
            raise ValueError("deletion index identity mismatch")
        paths.append(raw)
    if not index_only:
        remove_working_paths(root, paths)
    if paths and not working_only:
        # --index-info works in the bare verifier too; paths are literal bytes.
        data = b"".join(b"0 " + b"0" * len(index[path][1]) + b"\t" + path + b"\0"
                        for path in paths)
        git(root, "update-index", "-z", "--index-info", data=data)


def restore_phase(root, archive, phase):
    """Preserve the staged/unstaged distinction when replaying deletions."""
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
