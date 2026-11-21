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
from worktree_archive_git import capture_bundle, git, git_dirs
from worktree_archive_merge_index import merge_entries, merge_path, validate_merge_index, validate_merge_working
from worktree_archive_merge_objects import MERGE_FILES, merge_oid, merge_roots, validate_merge_metadata, verify_merge_objects


def merge_pending(root, *, admin=None):
    if admin is None:
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


def supported_merge_administration(root, admin=None, common=None):
    state = administration(root, allow_merge=True, dirs=(admin, common))
    if state['refs'] or 'SQUASH_MSG' in state['files'] or 'config.worktree' in state['files']:
        raise ValueError('merge:unsupported_private_state')
    if common is not None:
        # Git marks the repository shallow once `$GIT_COMMON_DIR/shallow` opens, even if empty.
        try:
            os.stat(Path(os.fsdecode(common)) / 'shallow')
            shallow = True
        except FileNotFoundError:
            shallow = False
    else:
        shallow = git(root, 'rev-parse', '--is-shallow-repository').strip() != b'false'
    if shallow:
        raise ValueError('merge:shallow_history')
    return state


def supported_merge_index(root):
    """Check index flags and intent-to-add; return this pass's `--stage` bytes.

    One `ls-files -v --stage` read yields the flags and the exact stage listing.
    The intent-to-add view pair runs whenever an empty-blob entry exists.
    """
    # Imported here: worktree_archive_state imports this module.
    from worktree_archive_state import intent_to_add_differs, tagged_index
    tags, index = tagged_index(root)
    if any(tag not in (b'H', b'M') for tag in tags):
        raise ValueError('merge:unsupported_index_flags')
    if intent_to_add_differs(root, index):
        raise ValueError('merge:intent_to_add')
    return index


def merge_working_paths(root, head, entries):
    paths = {entry[0] for entry in entries}
    for entry in git(root, 'ls-tree', '-r', '-z', head).split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            if metadata.split()[0] not in (b'100644', b'100755', b'120000'):
                raise ValueError('merge:unsupported_head_entry')
            paths.add(path.hex())
    attributes = git(root, 'check-attr', '-z', '--stdin', 'filter', data=b'\0'.join(bytes.fromhex(path) for path in sorted(paths)) + b'\0')
    if any(value not in (b'unspecified', b'unset') for value in attributes.split(b'\0')[2::3]):
        raise ValueError('merge:unsupported_filter')
    return sorted(paths)


def merge_working_file(root, path):
    from worktree_archive_filesystem import fingerprint, open_parent
    raw = merge_path(path)
    observed = fingerprint(root, raw, git_metadata=True)
    if observed == ['missing']:
        return None
    if observed[0] == 'symlink':
        return ['symlink', os.fsencode(observed[1]).hex()]
    if observed[0] != 'file':
        raise ValueError('merge:unsupported_file')
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


def merge_state(root, admin=None, common=None, head=None):
    """Capture a supported merge structurally; never copy a raw index or reflog.

    A caller may pass the HEAD its directory spawn resolved in this same pass.
    """
    state = supported_merge_administration(root, admin, common)
    entries = merge_entries(root, '--stage', listing=supported_merge_index(root))
    undo = merge_entries(root, '--resolve-undo')
    if head is None:
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
    admin, common = git_dirs(root)  # One spawn shared by the pending check and the capture.
    if not merge_pending(root, admin=admin):
        return
    state = merge_state(root, admin, common)
    # Full closure is intentional: MERGE_HEAD/ORIG_HEAD need not be ancestors of
    # HEAD or of the shared base. This bundle is independent of the source.
    capture_bundle(root, archive, merge_roots(state), '')
    (archive / 'merge-state-v1.json').write_text(json.dumps(state, sort_keys=True) + '\n', encoding='ascii')
