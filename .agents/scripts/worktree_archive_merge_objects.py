#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate merge metadata and the complete required object closure."""

import re

from worktree_archive_git import auto_merge_oid, git, validate_auto_merge


MERGE_FILES = {'MERGE_HEAD', 'MERGE_MSG', 'MERGE_MODE', 'ORIG_HEAD', 'AUTO_MERGE'}


def merge_oid(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value) or set(value) == {'0'}:
        raise ValueError('merge:invalid_oid')
    return value


def validate_merge_metadata(metadata):
    if not isinstance(metadata, dict) or not {'MERGE_HEAD', 'MERGE_MSG', 'ORIG_HEAD'}.issubset(metadata) or set(metadata) - MERGE_FILES:
        raise ValueError('merge:invalid_metadata')
    decoded = {name: bytes.fromhex(value) for name, value in metadata.items()}
    parents = decoded['MERGE_HEAD'].splitlines()
    if not parents or len(set(parents)) != len(parents) or decoded['MERGE_HEAD'] != b'\n'.join(parents) + b'\n':
        raise ValueError('merge:invalid_parents')
    auto_merge_oid(decoded['ORIG_HEAD'])
    for value in parents:
        merge_oid(value.decode('ascii'))
    if decoded.get('MERGE_MODE', b'') not in (b'', b'no-ff'):
        raise ValueError('merge:unsupported_mode')
    if 'AUTO_MERGE' in decoded:
        auto_merge_oid(decoded['AUTO_MERGE'])


def merge_roots(state):
    roots = {state['head']}
    for name in ('MERGE_HEAD', 'ORIG_HEAD', 'AUTO_MERGE'):
        for line in bytes.fromhex(state['metadata'].get(name, '')).splitlines():
            roots.add(merge_oid(line.decode('ascii')))
    roots.update(entry[2] for entry in state['index'] + state['undo'])
    return sorted(roots)


def verify_merge_objects(root, state):
    roots = merge_roots(state)
    for oid in [state['head']] + [line.decode('ascii') for name in ('MERGE_HEAD', 'ORIG_HEAD')
                               for line in bytes.fromhex(state['metadata'][name]).splitlines()]:
        if git(root, 'cat-file', '-t', oid).strip() != b'commit':
            raise ValueError('merge:parent_not_commit')
    for _, _, oid, _ in state['index'] + state['undo']:
        if git(root, 'cat-file', '-t', oid).strip() != b'blob':
            raise ValueError('merge:index_not_blob')
    if 'AUTO_MERGE' in state['metadata']:
        validate_auto_merge(root, bytes.fromhex(state['metadata']['AUTO_MERGE']).strip().decode('ascii'))
    closure = git(root, 'rev-list', '--objects', '--no-object-names', '--stdin',
                  data=('\n'.join(roots) + '\n').encode('ascii'))
    checked = git(root, 'cat-file', '--batch-check', data=closure)
    if len(checked.splitlines()) != len(closure.splitlines()) or any(line.endswith(b' missing') for line in checked.splitlines()):
        raise ValueError('merge:missing_object')
