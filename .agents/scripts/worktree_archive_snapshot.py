#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint supported recovery contents; refuse states not preserved by archives.

This is read-only evidence, not permission to remove a worktree. Callers must
still establish ownership/quiescence and compare again immediately before removal.
"""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def git(root, *args, data=None):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
    for name in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(name, None)
    return subprocess.run(["git", "-C", str(root), *args], input=data, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=60).stdout


def supported_state(root):
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    pending = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
               "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG", "index.lock", "config.worktree")
    if any((admin / name).exists() for name in pending):
        raise ValueError("unfinished Git operation is not supported for automatic archival")
    if git(root, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ValueError("shallow history is not self-contained")
    if git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"):
        raise ValueError("ignored content requires a separate preservation decision")
    flags = git(root, "ls-files", "-v", "-z").split(b"\0")
    if any(entry and entry[:1] != b"H" for entry in flags):
        raise ValueError("special index flags or unmerged entries are unsupported")
    # ls-files --stage cannot distinguish intent-to-add from a staged empty blob.
    visible = git(root, "diff", "--cached", "--raw", "-z", "--no-ext-diff", "--ita-visible-in-index")
    invisible = git(root, "diff", "--cached", "--raw", "-z", "--no-ext-diff", "--ita-invisible-in-index")
    if visible != invisible:
        raise ValueError("intent-to-add index entries require separate preservation")
    supported_history(root, admin)


def supported_history(root, admin):
    revisions = git(root, "reflog", "show", "--format=%H", "HEAD")
    previous = admin / "ORIG_HEAD"
    if previous.exists():
        if previous.is_symlink():
            raise ValueError("symlinked Git administrative state")
        revisions += previous.read_bytes() + b"\n"
    # rev-list stops reading revisions at a blank line, so normalize ORIG_HEAD's
    # trailing newline before appending the exclusion.
    revisions = b"\n".join(line for line in revisions.splitlines() if line) + b"\n^HEAD\n"
    if git(root, "rev-list", "--max-count=1", "--stdin", data=revisions):
        raise ValueError("reflog-only or previous HEAD history requires separate preservation")
    if git(root, "for-each-ref", "--format=%(refname)", "refs/worktree/", "refs/bisect/", "refs/rewritten/"):
        raise ValueError("private worktree refs require separate preservation")
    message = admin / "COMMIT_EDITMSG"
    if message.exists():
        if message.is_symlink() or message.read_bytes().rstrip(b"\n") != git(root, "log", "-1", "--format=%B").rstrip(b"\n"):
            raise ValueError("uncommitted message draft requires separate preservation")


def inventories(root):
    index = git(root, "ls-files", "--stage", "-z")
    paths = set()
    for entry in index.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, _, stage = metadata.split()
        if stage != b"0" or mode not in (b"100644", b"100755", b"120000"):
            raise ValueError("submodules or unmerged entries require separate preservation")
        paths.add(path)
    attributes = git(root, "check-attr", "-z", "--stdin", "filter", data=b"\0".join(sorted(paths)) + b"\0") if paths else b""
    fields = attributes.split(b"\0")
    if any(value not in (b"unspecified", b"unset") for value in fields[2::3]):
        raise ValueError("Git filters, including local LFS payloads, require separate preservation")
    paths.update(path for path in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if path)
    return index, sorted(paths)


def unreadable_directory(error):
    raise error


def supported_metadata(observed, attributes):
    if observed.st_uid != os.geteuid() or observed.st_gid != os.getegid() or attributes:
        raise ValueError("ownership, ACLs or extended attributes require separate preservation")
    directory = stat.S_ISDIR(observed.st_mode)
    allowed = (0o755,) if directory else ((0o777,) if stat.S_ISLNK(observed.st_mode) else (0o644, 0o755))
    if stat.S_IMODE(observed.st_mode) not in allowed or (not directory and observed.st_nlink != 1):
        raise ValueError("special permissions or hard links require separate preservation")


def supported_directories(root):
    if not hasattr(os, "listxattr"):
        raise ValueError("filesystem metadata inspection unavailable")
    for directory, directories, files in os.walk(root, followlinks=False, onerror=unreadable_directory):
        current = Path(directory)
        supported_metadata(current.lstat(), os.listxattr(current, follow_symlinks=False))
        if current == root:
            directories[:] = [name for name in directories if name != ".git"]
        elif ".git" in directories or ".git" in files:
            raise ValueError("nested repository requires separate preservation")
        if current != root and not directories and not files:
            raise ValueError("empty directories are not represented in this archive format")


def regular_fingerprint(path, parent):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("unsupported filesystem object")
        supported_metadata(before, os.listxattr(source.fileno()))
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError("source changed while fingerprinting")
    return ["file", stat.S_IMODE(before.st_mode), before.st_size, digest.hexdigest()]


def open_parent(root, parts):
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in parts:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def fingerprint(root, raw):
    relative = Path(os.fsdecode(raw))
    if relative.is_absolute() or ".." in relative.parts or ".git" in relative.parts:
        raise ValueError("unsafe recovery path")
    try:
        parent = open_parent(root, relative.parts[:-1])
    except FileNotFoundError:
        return ["missing"]
    try:
        try:
            observed = os.stat(relative.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return ["missing"]
        if stat.S_ISLNK(observed.st_mode):
            supported_metadata(observed, os.listxattr(root / relative, follow_symlinks=False))
            return ["symlink", os.readlink(relative.name, dir_fd=parent)]
        if not stat.S_ISREG(observed.st_mode):
            raise ValueError("unsupported recovery file type")
        return regular_fingerprint(relative.name, parent)
    finally:
        os.close(parent)


def snapshot(path):
    root = Path(path).resolve(strict=True)
    supported_state(root)
    index, paths = inventories(root)
    supported_directories(root)
    head = git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii")
    contents = [[os.fsdecode(raw), fingerprint(root, raw)] for raw in paths]
    payload = json.dumps([head, index.hex(), contents], ensure_ascii=True, separators=(",", ":")).encode("ascii")
    # Git/index mutations during sampling are not a valid stable snapshot.
    if inventories(root) != (index, paths) or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii") != head:
        raise ValueError("Git state changed while fingerprinting")
    supported_state(root)
    working_bytes = sum(value[2] for _, value in contents if value[0] == "file")
    return {"schema": 1, "head": head, "files": len(paths), "bytes": working_bytes,
            "sha256": hashlib.sha256(payload).hexdigest()}


def main(argv):
    if len(argv) != 1:
        raise ValueError("usage: worktree_archive_snapshot.py WORKTREE")
    print(json.dumps(snapshot(argv[0]), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "source evidence unavailable"
        print(f"archive-snapshot: {reason}", file=sys.stderr)
        sys.exit(1)
