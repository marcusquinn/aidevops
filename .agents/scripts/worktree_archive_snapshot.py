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
import tempfile

from worktree_archive_filesystem import fingerprint, supported_directories
from worktree_archive_administration import (
    ADMIN_FILES, administration, git, load_administration,
    OPERATIONS as OPERATIONS,
)
from worktree_archive_state import inventories, supported_state


def administration_digest(state):
    # Keep fingerprints small enough for the existing shell/argv interface even
    # when a repository's raw index or reflog is many megabytes.
    payload = json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')
    return hashlib.sha256(payload).hexdigest()


def administration_roots(root, state):
    roots = {git(root, "rev-parse", "HEAD").strip().decode("ascii")}
    roots.update(state["refs"].values())
    for name, encoded in state["files"].items():
        data = bytes.fromhex(encoded)
        if name == "logs/HEAD":
            for line in data.splitlines():
                roots.update(part.decode("ascii") for part in line.split()[:2] if set(part) != {48})
        elif name == "ORIG_HEAD":
            roots.add(data.strip().decode("ascii"))
    for inventory in ('--stage', '--resolve-undo'):
        for entry in git(root, "ls-files", inventory, "-z").split(b"\0"):
            if entry:
                oid = entry.split(b"\t", 1)[0].split()[1]
                if set(oid) != {48}:
                    roots.add(oid.decode("ascii"))
    return sorted(roots)


def capture_administration(root, archive, include_ignored):
    supported_state(root, True, include_ignored)
    inventories(root)
    state = administration(root)
    # Scratch refs make every root (including index-only blobs) a named bundle
    # tip. All writes go to scratch; the source object database is read-only.
    with tempfile.TemporaryDirectory(prefix=".admin-bundle-", dir=archive.parent) as temporary:
        scratch = Path(temporary)
        object_format = git(root, 'rev-parse', '--show-object-format').strip().decode('ascii')
        git(scratch, "init", "--bare", "--quiet", f'--object-format={object_format}')
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").rstrip(b"\n")
        (scratch / "objects/info/alternates").write_bytes(objects + b"\n")
        for number, oid in enumerate(administration_roots(root, state)):
            git(scratch, "update-ref", f"refs/archive/{number}", oid)
        git(scratch, "update-ref", "refs/heads/archive-head", git(root, "rev-parse", "HEAD").strip().decode("ascii"))
        git(scratch, "bundle", "create", str(archive / "commits.bundle"), "--all")
    (archive / "git-admin.json").write_text(json.dumps(state, sort_keys=True) + "\n", encoding="ascii")


def restore_administration(root, archive):
    state = load_administration(archive)
    # Clone fetches branch tips only. Import all preservation tips explicitly.
    git(root, "fetch", "--quiet", "--no-write-fetch-head", str(archive / "commits.bundle"),
        "+refs/archive/*:refs/archive/*")
    admin = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    head = bytes.fromhex(state["files"]["HEAD"])
    if head.startswith(b"ref: "):
        branch = os.fsdecode(head[5:].strip())
        if not branch.startswith("refs/heads/"):
            raise ValueError("git_admin:unsupported_head")
        git(root, "update-ref", branch, git(root, "rev-parse", "HEAD").strip().decode("ascii"))
    for name, oid in state["refs"].items():
        git(root, "update-ref", name, oid)
    for name in ADMIN_FILES - state['files'].keys():
        (admin / name).unlink(missing_ok=True)
    for name, value in state["files"].items():
        target = admin / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(bytes.fromhex(value))
    if "config.worktree" in state["files"]:
        git(root, "config", "--file", str(admin / "config"), "extensions.worktreeConfig", "true")


def verify_administration(archive, scratch, manifest):
    """Prove every admin/index object is available without the source database."""
    state = load_administration(archive)
    if administration_digest(state) != manifest.get('source_fingerprint', {}).get('git_admin'):
        raise ValueError('git_admin:fingerprint_mismatch')
    git(scratch, 'fetch', '--quiet', '--no-write-fetch-head', str(archive / 'commits.bundle'),
        '+refs/archive/*:refs/archive/*')
    git(scratch, 'update-ref', 'HEAD', manifest['head_sha'])
    (scratch / 'index').write_bytes(bytes.fromhex(state['files']['index']))
    roots = administration_roots(scratch, state)
    checked = git(scratch, 'cat-file', '--batch-check', data=('\n'.join(roots) + '\n').encode('ascii'))
    if len(checked.splitlines()) != len(roots) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('git_admin:missing_object')


def snapshot(path, preserve_git_admin=False):
    root = Path(path).resolve(strict=True)
    supported_state(root, preserve_git_admin)
    index, paths = inventories(root)
    supported_directories(root)
    head = git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii")
    contents = [[os.fsdecode(raw), fingerprint(root, raw)] for raw in paths]
    values = [head, index.hex(), contents]
    if preserve_git_admin:
        values.append(administration(root))
    payload = json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    # Git/index mutations during sampling are not a valid stable snapshot.
    if inventories(root) != (index, paths) or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii") != head:
        raise ValueError("Git state changed while fingerprinting")
    supported_state(root, preserve_git_admin)
    working_bytes = sum(value[2] for _, value in contents if value[0] == "file")
    return {"schema": 1, "head": head, "files": len(paths), "bytes": working_bytes,
            "sha256": hashlib.sha256(payload).hexdigest()}


def main(argv):
    if argv and argv[0] == "admin-capture" and len(argv) == 4:
        capture_administration(Path(argv[1]), Path(argv[2]).resolve(), argv[3] == "1")
        return 0
    if argv and argv[0] == "admin-restore" and len(argv) == 3:
        restore_administration(Path(argv[1]), Path(argv[2]).resolve())
        return 0
    if argv and argv[0] == "admin-verify" and len(argv) == 2:
        load_administration(Path(argv[1]))
        return 0
    if len(argv) == 2 and argv[0] == "--preserve-git-admin":
        print(json.dumps(snapshot(argv[1], True), sort_keys=True))
        return 0
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
