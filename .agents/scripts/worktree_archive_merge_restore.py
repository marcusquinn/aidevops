#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Reconstruct supported merge working files and operation metadata."""

import json
import os
from pathlib import Path
import tarfile

from worktree_archive_git import fetch_preservation, git
from worktree_archive_merge_capture import load_merge
from worktree_archive_merge_index import merge_path, restore_merge_index
from worktree_archive_merge_objects import MERGE_FILES, verify_merge_objects


def write_merge_working(root, path, value):
    from worktree_archive_filesystem import open_parent
    relative = Path(os.fsdecode(merge_path(path)))
    target = root / relative
    if target.is_symlink():
        raise ValueError('merge:symlink_target')
    if value is not None:
        target.parent.mkdir(parents=True, exist_ok=True)
    try:
        parent = open_parent(root, relative.parts[:-1])
    except FileNotFoundError:
        if value is None:
            return
        raise
    try:
        if value is None:
            try:
                os.unlink(relative.name, dir_fd=parent)
            except FileNotFoundError:
                pass
        else:
            descriptor = os.open(relative.name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                                 0o600, dir_fd=parent)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(bytes.fromhex(value[1]))
                os.fchmod(stream.fileno(), value[0])
    finally:
        os.close(parent)


def restore_merge_working(root, archive, state):
    # Remove the clean checkout first, then create parents using no-follow file
    # descriptors. Symlinks and directory/file conflicts are deliberately refused.
    untracked = set()
    if (archive / 'untracked.tar.gz').exists():
        with tarfile.open(archive / 'untracked.tar.gz', 'r:gz') as payload:
            untracked = {os.fsencode(member.name).hex() for member in payload.getmembers()}
    for path, value in state['working'].items():
        if path in untracked:
            value = None  # The verified untracked payload owns these bytes.
        write_merge_working(root, path, value)


def restore_merge_metadata(root, state):
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    for name in MERGE_FILES:
        target = admin / name
        if os.path.lexists(target):
            if target.is_symlink() or not target.is_file():
                raise ValueError('merge:unsafe_admin_target')
            target.unlink()
        if name in state['metadata']:
            target.write_bytes(bytes.fromhex(state['metadata'][name]))


def restore_merge(root, archive):
    manifest = json.loads((archive / 'manifest.json').read_text(encoding='ascii'))
    state = load_merge(archive, manifest)
    fetch_preservation(root, archive)
    verify_merge_objects(root, state)
    restore_merge_index(root, state)
    restore_merge_working(root, archive, state)
    restore_merge_metadata(root, state)
