#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Create deterministic commits for plugin trust tests without Git mutations."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import sys
import zlib


def write_object(git_dir: Path, object_type: bytes, content: bytes) -> str:
    payload = object_type + b" " + str(len(content)).encode() + b"\0" + content
    # Git object IDs require SHA-1 compatibility; this is not a security digest.
    object_id = hashlib.sha1(payload, usedforsecurity=False).hexdigest()
    object_path = git_dir / "objects" / object_id[:2] / object_id[2:]
    object_path.parent.mkdir(parents=True, exist_ok=True)
    if not object_path.exists():
        object_path.write_bytes(zlib.compress(payload))
    return object_id


def write_tree(git_dir: Path, directory: Path) -> str:
    entries: list[tuple[bytes, bytes, str]] = []
    for child in directory.iterdir():
        if child.name == ".git":
            continue
        name = os.fsencode(child.name)
        if child.is_symlink():
            mode = b"120000"
            object_id = write_object(git_dir, b"blob", os.fsencode(os.readlink(child)))
        elif child.is_dir():
            mode = b"40000"
            object_id = write_tree(git_dir, child)
        else:
            mode = b"100755" if os.access(child, os.X_OK) else b"100644"
            object_id = write_object(git_dir, b"blob", child.read_bytes())
        entries.append((name, mode, object_id))

    content = b"".join(
        mode + b" " + name + b"\0" + bytes.fromhex(object_id)
        for name, mode, object_id in sorted(entries, key=lambda entry: entry[0])
    )
    return write_object(git_dir, b"tree", content)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: plugin-git-fixture.py <repo> <message>", file=sys.stderr)
        return 2

    repo = Path(sys.argv[1])
    message = sys.argv[2]
    git_dir = repo / ".git"
    ref = git_dir / "refs" / "heads" / "main"
    (git_dir / "objects").mkdir(parents=True, exist_ok=True)
    ref.parent.mkdir(parents=True, exist_ok=True)
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    (git_dir / "config").write_text(
        "[core]\n\trepositoryformatversion = 0\n\tbare = false\n",
        encoding="utf-8",
    )

    tree_id = write_tree(git_dir, repo)
    parent = ref.read_text(encoding="utf-8").strip() if ref.exists() else ""
    lines = [f"tree {tree_id}"]
    if parent:
        lines.append(f"parent {parent}")
    identity = "Plugin Test <plugin-test@example.invalid> 1700000000 +0000"
    lines.extend([f"author {identity}", f"committer {identity}", "", message, ""])
    commit_id = write_object(git_dir, b"commit", "\n".join(lines).encode())
    ref.write_text(f"{commit_id}\n", encoding="utf-8")
    print(commit_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
