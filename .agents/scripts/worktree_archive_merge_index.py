#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate and reconstruct structured merge index entries and paths."""

import os

from worktree_archive_git import git
from worktree_archive_merge_objects import merge_oid


def merge_path(value):
    raw = bytes.fromhex(value)
    parts = raw.split(b'/')
    if raw.hex() != value or not raw or b'\0' in raw or any(part in (b'', b'.', b'..') or part.lower() == b'.git' for part in parts):
        raise ValueError('merge:unsafe_path')
    return raw


def merge_entries(root, option):
    result = []
    for entry in git(root, 'ls-files', option, '-z').split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            mode, oid, stage = metadata.decode('ascii').split()
            result.append([path.hex(), mode, oid, int(stage)])
    return result


def validate_merge_index(entries, stages):
    paths = set()
    seen = {}
    for path, mode, oid, stage in entries:
        raw = merge_path(path)
        if mode not in ('100644', '100755') or not isinstance(stage, int) or isinstance(stage, bool) or stage not in stages:
            raise ValueError('merge:unsupported_index_entry')
        merge_oid(oid)
        current = seen.setdefault(raw, set())
        if stage in current or (current and (stage == 0 or 0 in current)):
            raise ValueError('merge:duplicate_index_entry')
        current.add(stage)
        paths.add(path)
    return paths


def validate_merge_working(working, paths):
    if not isinstance(working, dict) or not paths.issubset(working):
        raise ValueError('merge:incomplete_working_files')
    for path, value in working.items():
        raw = merge_path(path)
        if any(b'/'.join(raw.split(b'/')[:number]).hex() in working for number in range(1, len(raw.split(b'/')))):
            raise ValueError('merge:directory_file_conflict')
        if value is not None:
            if not isinstance(value, list) or len(value) != 2 or value[0] not in (0o644, 0o755):
                raise ValueError('merge:invalid_working_file')
            bytes.fromhex(value[1])


def restore_merge_index(root, state):
    # Rebuild REUC via Git's normal resolve operations, including staged deletes.
    git(root, 'read-tree', '--empty')
    unresolved = state['undo'] + [entry for entry in state['index'] if entry[3] != 0]
    def index_info(entries):
        payload = b''.join(f'{mode} {oid} {stage}\t'.encode('ascii') + merge_path(path) + b'\0'
                           for path, mode, oid, stage in entries)
        if payload:
            git(root, 'update-index', '-z', '--index-info', data=payload)
    index_info(unresolved)
    index_info([entry for entry in state['index'] if entry[3] == 0])
    live = {entry[0] for entry in state['index']}
    for path in sorted({entry[0] for entry in state['undo']} - live):
        git(root, 'update-index', '--force-remove', '--', os.fsdecode(merge_path(path)))
