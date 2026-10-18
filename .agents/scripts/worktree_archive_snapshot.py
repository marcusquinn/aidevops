#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint supported recovery contents; refuse states not preserved by archives.

This is read-only evidence, not permission to remove a worktree. Callers must
still establish ownership/quiescence and compare again immediately before removal.
Sampling is not atomic: cooperating-writer exclusion must cover verification and
removal; fingerprints do not fence arbitrary same-user writers.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from worktree_archive_filesystem import fingerprint, supported_directories

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
               "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG", "index.lock", "config.worktree", "SQUASH_MSG")
    if any((admin / name).exists() for name in pending):
        raise ValueError("unfinished Git operation is not supported for automatic archival")
    supported_administration(root, admin)
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


def supported_administration(root, admin):
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").rstrip(b"\n")))
    if admin.resolve() == common.resolve():
        # Independent restores are full repositories. Managed source enrollment
        # separately refuses canonical repositories; only linked admin is removed.
        return
    allowed = {"HEAD", "index", "commondir", "gitdir", "ORIG_HEAD", "COMMIT_EDITMSG", "logs", "refs"}
    for entry in admin.iterdir():
        if entry.name not in allowed or entry.is_symlink():
            raise ValueError(f"unknown Git administrative state requires separate preservation: {entry.name!r}")
        if entry.name == "logs":
            if not entry.is_dir() or any(child.name != "HEAD" or child.is_symlink()
                                         or not child.is_file() for child in entry.iterdir()):
                raise ValueError("unknown Git administrative log requires separate preservation")
        elif entry.name == "refs":
            # Recent Git creates this empty directory for a new linked worktree.
            if not entry.is_dir() or any(entry.iterdir()):
                raise ValueError("private Git references require separate preservation")
        elif not entry.is_file():
            raise ValueError("unsupported Git administrative entry")


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
