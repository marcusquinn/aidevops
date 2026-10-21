#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capture a supported merge without copying raw Git administration."""

import hashlib
import json
import os
from pathlib import Path
import stat

from worktree_archive_administration import administration
from worktree_archive_git import capture_bundle, git
from worktree_archive_merge_index import merge_entries, merge_path, validate_merge_index, validate_merge_working
from worktree_archive_merge_objects import MERGE_FILES, merge_oid, merge_roots, validate_merge_metadata, verify_merge_objects


def merge_pending(root):
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    return os.path.lexists(admin / 'MERGE_HEAD')


def validate_merge(state):
    if not isinstance(state, dict) or set(state) != {'schema', 'head', 'metadata', 'index', 'undo', 'working'} or state['schema'] != 1:
        raise ValueError('merge:invalid_state')
    merge_oid(state['head'])
    validate_merge_metadata(state['metadata'])
    paths = validate_merge_index(state['index'], {0, 1, 2, 3})
    paths.update(validate_merge_index(state['undo'], {1, 2, 3}))
    validate_merge_working(state['working'], paths)
    return state


def supported_merge_administration(root):
    state = administration(root, allow_merge=True)
    if state['refs'] or 'SQUASH_MSG' in state['files'] or 'config.worktree' in state['files']:
        raise ValueError('merge:unsupported_private_state')
    if git(root, 'rev-parse', '--is-shallow-repository').strip() != b'false':
        raise ValueError('merge:shallow_history')
    draft = bytes.fromhex(state['files'].get('COMMIT_EDITMSG', '')).rstrip(b'\n')
    if draft and draft != git(root, 'log', '-1', '--format=%B').rstrip(b'\n'):
        raise ValueError('merge:uncommitted_message_draft')
    if state['files'].get('FETCH_HEAD'):
        raise ValueError('merge:unpreserved_fetch_head')
    return state


def supported_merge_index(root):
    flags = git(root, 'ls-files', '-v', '-z').split(b'\0')
    if any(entry and entry[:1] not in (b'H', b'M') for entry in flags):
        raise ValueError('merge:unsupported_index_flags')
    options = ('--cached', '--raw', '-z', '--no-ext-diff')
    if git(root, 'diff', *options, '--ita-visible-in-index') != git(root, 'diff', *options, '--ita-invisible-in-index'):
        raise ValueError('merge:intent_to_add')


def merge_working_paths(root, head, entries):
    paths = {entry[0] for entry in entries}
    for entry in git(root, 'ls-tree', '-r', '-z', head).split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            if metadata.split()[0] not in (b'100644', b'100755'):
                raise ValueError('merge:unsupported_head_entry')
            paths.add(path.hex())
    attributes = git(root, 'check-attr', '-z', '--stdin', 'filter', data=b'\0'.join(bytes.fromhex(path) for path in sorted(paths)) + b'\0')
    if any(value not in (b'unspecified', b'unset') for value in attributes.split(b'\0')[2::3]):
        raise ValueError('merge:unsupported_filter')
    return sorted(paths)


def merge_working_file(root, path):
    from worktree_archive_filesystem import fingerprint, open_parent
    raw = merge_path(path)
    observed = fingerprint(root, raw)
    if observed == ['missing']:
        return None
    if observed[0] != 'file':
        raise ValueError('merge:symlink_not_supported')
    relative = Path(os.fsdecode(raw))
    parent = open_parent(root, relative.parts[:-1])
    try:
        descriptor = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('merge:unsupported_file')
            content = stream.read()
        if hashlib.sha256(content).hexdigest() != observed[3]:
            raise ValueError('merge:source_changed')
        return [observed[1], content.hex()]
    finally:
        os.close(parent)


def merge_state(root):
    """Capture a supported merge structurally; never copy a raw index or reflog."""
    state = supported_merge_administration(root)
    supported_merge_index(root)
    entries = merge_entries(root, '--stage')
    undo = merge_entries(root, '--resolve-undo')
    head = git(root, 'rev-parse', 'HEAD').strip().decode('ascii')
    paths = merge_working_paths(root, head, entries + undo)
    working = {path: merge_working_file(root, path) for path in paths}
    result = validate_merge({'schema': 1, 'head': head, 'metadata': {name: value for name, value in state['files'].items() if name in MERGE_FILES},
                             'index': entries, 'undo': undo, 'working': working})
    verify_merge_objects(root, result)
    return result


def merge_digest(state):
    return hashlib.sha256(json.dumps(state, sort_keys=True, separators=(',', ':')).encode('ascii')).hexdigest()


def load_merge(archive, manifest):
    state = validate_merge(json.loads((archive / 'merge-state-v1.json').read_text(encoding='ascii')))
    saved = manifest.get('source_fingerprint', {})
    if state['head'] != manifest['head_sha'] or merge_digest(state) != saved.get('merge_sha256'):
        raise ValueError('merge:fingerprint_mismatch')
    return state


def capture_merge(root, archive):
    if not merge_pending(root):
        return
    state = merge_state(root)
    # Full closure is intentional: MERGE_HEAD/ORIG_HEAD need not be ancestors of
    # HEAD or of the shared base. This bundle is independent of the source.
    capture_bundle(root, archive, merge_roots(state), '')
    (archive / 'merge-state-v1.json').write_text(json.dumps(state, sort_keys=True) + '\n', encoding='ascii')
