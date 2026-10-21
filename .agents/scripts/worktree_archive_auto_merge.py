#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capture, verify and restore the AUTO_MERGE tree and its object closure."""

import json
import os
from pathlib import Path
import stat

from worktree_archive_administration import validate_admin_entry
from worktree_archive_git import (
    auto_merge_oid, capture_bundle, fetch_preservation, git, validate_auto_merge,
)


def auto_merge(root):
    path = Path(os.fsdecode(git(root, "rev-parse", "--absolute-git-dir").rstrip(b"\n"))) / "AUTO_MERGE"
    if not os.path.lexists(path):
        return None
    validate_admin_entry(path, "AUTO_MERGE")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('git_admin:AUTO_MERGE_not_regular')
        oid = auto_merge_oid(stream.read(66))
    validate_auto_merge(root, oid)
    return oid


def capture_auto_merge(root, archive, base):
    oid = auto_merge(root)
    if oid is None:
        return
    # Reuse the single bundle and exclude only objects durably covered by base.
    covered = git(root, 'rev-list', '--objects', '--no-object-names', base).splitlines()
    roots = [value for value in (git(root, 'rev-parse', 'HEAD').strip().decode('ascii'), oid)
             if value.encode('ascii') not in covered]
    if roots:
        capture_bundle(root, archive, roots, base)
    (archive / 'auto-merge-v1.json').write_text(
        json.dumps({'schema': 1, 'tree': oid}) + '\n', encoding='ascii')


def verify_auto_merge(root, archive, manifest):
    oid = manifest.get('source_fingerprint', {}).get('auto_merge')
    path = archive / 'auto-merge-v1.json'
    if oid is None:
        if path.exists():
            raise ValueError('git_admin:unexpected_AUTO_MERGE_artifact')
        return None
    auto_merge_oid(oid.encode('ascii'))
    if json.loads(path.read_text(encoding='ascii')) != {'schema': 1, 'tree': oid}:
        raise ValueError('git_admin:AUTO_MERGE_metadata_mismatch')
    validate_auto_merge(root, oid)
    # rev-list traverses trees; batch-check additionally proves every blob exists.
    closure = git(root, 'rev-list', '--objects', '--no-object-names', oid)
    checked = git(root, 'cat-file', '--batch-check', data=closure)
    if len(checked.splitlines()) != len(closure.splitlines()) or any(
            line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('git_admin:missing_AUTO_MERGE_object')
    return oid


def restore_auto_merge(root, archive):
    manifest = json.loads((archive / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('source_fingerprint', {}).get('auto_merge') is None:
        return
    fetch_preservation(root, archive)
    oid = verify_auto_merge(root, archive, manifest)
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    (admin / 'AUTO_MERGE').write_text(oid + '\n', encoding='ascii')
