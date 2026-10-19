#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint supported recovery contents; refuse states not preserved by archives.

This is read-only evidence, not permission to remove a worktree. Callers must
still establish ownership/quiescence and compare again immediately before removal.
Sampling is not atomic: cooperating-writer exclusion must cover verification and
removal; fingerprints do not fence arbitrary same-user writers.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from worktree_archive_filesystem import fingerprint, supported_directories
from worktree_archive_administration import (
    ADMIN_FILES, administration, git, load_administration,
    OPERATIONS as OPERATIONS,
)
from worktree_archive_state import inventories, supported_state
from worktree_archive_objects import administration_roots, bundle_roots


def administration_digest(state):
    # Keep fingerprints small enough for the existing shell/argv interface even
    # when a repository's raw index or reflog is many megabytes.
    payload = json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')
    return hashlib.sha256(payload).hexdigest()


def capture_administration(root, archive, include_ignored, base=''):
    supported_state(root, True, include_ignored)
    inventories(root)
    state = administration(root)
    roots = set(bundle_roots(root, state))
    if base:
        if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', base):
            raise ValueError('git_admin:invalid_base')
        covered = git(root, 'rev-list', '--objects', '--no-object-names', base)
        roots.difference_update(oid.decode('ascii') for oid in covered.splitlines())
    if roots:
        capture_bundle(root, archive, sorted(roots), base)
    (archive / 'git-admin.json').write_text(json.dumps(state, sort_keys=True) + '\n', encoding='ascii')


def capture_bundle(root, archive, roots, base):
    # Scratch refs make every root (including index-only blobs) a named bundle
    # tip. All writes go to scratch; the source object database is read-only.
    with tempfile.TemporaryDirectory(prefix=".admin-bundle-", dir=archive.parent) as temporary:
        scratch = Path(temporary)
        object_format = git(root, 'rev-parse', '--show-object-format').strip().decode('ascii')
        git(scratch, "init", "--bare", "--quiet", f'--object-format={object_format}')
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").rstrip(b"\n")
        (scratch / "objects/info/alternates").write_bytes(objects + b"\n")
        updates = ''.join(f'update refs/archive/{number} {oid}\n'
                          for number, oid in enumerate(roots))
        git(scratch, "update-ref", "--stdin", data=updates.encode('ascii'))
        git(scratch, "update-ref", "refs/heads/archive-head", git(root, "rev-parse", "HEAD").strip().decode("ascii"))
        exclusions = (f'^{base}',) if base else ()
        git(scratch, "bundle", "create", str(archive / "commits.bundle"), "--all", *exclusions)


def fetch_preservation(root, archive):
    bundle = archive / 'commits.bundle'
    if bundle.is_file():
        git(root, 'fetch', '--quiet', '--no-write-fetch-head', str(bundle),
            '+refs/archive/*:refs/archive/*')


def seed_base(root, manifest):
    """Import only the recorded base graph, never unrelated source objects."""
    base = manifest['base_sha']
    common = Path(manifest.get('source_git_common_dir', ''))
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', base):
        raise ValueError('git_admin:invalid_base')
    if not common.is_absolute() or not common.is_dir():
        raise ValueError('git_admin:base_repository_unavailable')
    git(root, '-c', 'core.hooksPath=/dev/null', 'fetch', '--quiet', '--no-tags',
        '--no-write-fetch-head', str(common), base)
    git(root, 'update-ref', 'refs/archive/base', base)


def prepare_incremental_restore(archive, target):
    manifest = json.loads((archive / 'manifest.json').read_text(encoding='utf-8'))
    target.mkdir(mode=0o755)
    object_format = 'sha256' if len(manifest['head_sha']) == 64 else 'sha1'
    git(target, 'init', '--quiet', f'--object-format={object_format}')
    seed_base(target, manifest)
    fetch_preservation(target, archive)
    git(target, '-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', manifest['head_sha'])


def restore_administration(root, archive):
    state = load_administration(archive)
    # Clone fetches branch tips only. Import all preservation tips explicitly.
    fetch_preservation(root, archive)
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
        # Newly reconstructed metadata directories may contain private state.
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(bytes.fromhex(value))
    if "config.worktree" in state["files"]:
        git(root, "config", "--file", str(admin / "config"), "extensions.worktreeConfig", "true")


def verify_administration(archive, scratch, manifest):
    """Prove every admin/index object is available without the source database."""
    state = load_administration(archive)
    if administration_digest(state) != manifest.get('source_fingerprint', {}).get('git_admin'):
        raise ValueError('git_admin:fingerprint_mismatch')
    fetch_preservation(scratch, archive)
    git(scratch, 'update-ref', 'HEAD', manifest['head_sha'])
    (scratch / 'index').write_bytes(bytes.fromhex(state['files']['index']))
    roots = administration_roots(scratch, state)
    checked = git(scratch, 'cat-file', '--batch-check', data=('\n'.join(roots) + '\n').encode('ascii'))
    if len(checked.splitlines()) != len(roots) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('git_admin:missing_object')


def snapshot(path, preserve_git_admin=False, include_ignored=False):
    root = Path(path).resolve(strict=True)
    supported_state(root, preserve_git_admin, include_ignored)
    index, paths = inventories(root, include_ignored)
    supported_directories(root)
    head = git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii")
    contents = [[os.fsdecode(raw), fingerprint(root, raw)] for raw in paths]
    values = [head, index.hex(), contents]
    if preserve_git_admin:
        values.append(administration(root))
    payload = json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    # Git/index mutations during sampling are not a valid stable snapshot.
    if inventories(root, include_ignored) != (index, paths) or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii") != head:
        raise ValueError("Git state changed while fingerprinting")
    supported_state(root, preserve_git_admin, include_ignored)
    working_bytes = sum(value[2] for _, value in contents if value[0] == "file")
    return {"schema": 1, "head": head, "files": len(paths), "bytes": working_bytes,
            "sha256": hashlib.sha256(payload).hexdigest()}


def main(argv):
    command = argv[0] if argv else ''
    if command == "admin-capture" and len(argv) in (4, 5):
        capture_administration(Path(argv[1]), Path(argv[2]).resolve(), argv[3] == "1", *argv[4:])
        return 0
    if command == 'admin-prepare-restore' and len(argv) == 3:
        prepare_incremental_restore(Path(argv[1]).resolve(), Path(argv[2]).resolve())
        return 0
    if command == "admin-restore" and len(argv) == 3:
        restore_administration(Path(argv[1]), Path(argv[2]).resolve())
        return 0
    if command == "admin-verify" and len(argv) == 2:
        load_administration(Path(argv[1]))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preserve-git-admin", action="store_true")
    parser.add_argument("--include-ignored", action="store_true")
    parser.add_argument("worktree")
    args = parser.parse_args(argv)
    print(json.dumps(snapshot(args.worktree, args.preserve_git_admin, args.include_ignored), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else "source evidence unavailable"
        print(f"archive-snapshot: {reason}", file=sys.stderr)
        sys.exit(1)
