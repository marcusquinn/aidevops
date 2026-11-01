#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Verify Git-only deltas against their retained local base without checkout."""

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from worktree_archive_git import git
from worktree_archive_auto_merge import verify_auto_merge
from worktree_archive_merge_objects import merge_roots, verify_merge_objects


def imported_objects(scratch, archive):
    """Inspect the actual bundle pack, not objects merely available in the source."""
    bundle = archive / 'commits.bundle'
    if not bundle.is_file():
        return set()
    git(scratch, 'bundle', 'verify', str(bundle))
    git(scratch, 'bundle', 'unbundle', str(bundle))
    result = set()
    for index in (scratch / 'objects/pack').glob('*.idx'):
        # verify-pack checks the archived pack, not the shared repository packs.
        for line in git(scratch, 'verify-pack', '-v', str(index)).splitlines():
            fields = line.split()
            if fields and re.fullmatch(rb'(?:[0-9a-f]{40}|[0-9a-f]{64})', fields[0]):
                result.add(fields[0])
    return result


def verify_patches(scratch, archive, manifest):
    """Reconstruct only the index; bind both patches to the captured fingerprint."""
    head = manifest['head_sha']
    git(scratch, 'read-tree', head)
    staged = (archive / 'staged.patch').read_bytes()
    unstaged = (archive / 'diff.patch').read_bytes()
    if staged:
        git(scratch, 'apply', '--cached', str(archive / 'staged.patch'))
    index = git(scratch, 'ls-files', '--stage', '-z')
    values = [head, hashlib.sha256(index).hexdigest(),
              hashlib.sha256(staged).hexdigest(), hashlib.sha256(unstaged).hexdigest()]
    digest = hashlib.sha256(json.dumps(values).encode('ascii')).hexdigest()
    saved = manifest['source_fingerprint']
    if saved.get('head') != head or saved.get('sha256') != digest:
        raise ValueError('archive-local:patch-or-index-mismatch')
    if unstaged:
        git(scratch, 'apply', '--cached', '--check', str(archive / 'diff.patch'))


def payload_roots(scratch, archive, manifest):
    if manifest.get('merge_policy') == 'structured-v1':
        from worktree_archive_state import load_merge
        state = load_merge(archive, manifest)
        verify_merge_objects(scratch, state)
        return merge_roots(state)
    verify_patches(scratch, archive, manifest)
    extra = verify_auto_merge(scratch, archive, manifest)
    return [manifest['head_sha']] + ([extra] if extra else [])


def base_objects(common):
    """Require a canonical local store that can be represented as one alternate."""
    if not common.is_absolute() or common.resolve(strict=True) != common:
        raise ValueError('archive-local:unsupported-base-store')
    objects = common / 'objects'
    if (objects.resolve(strict=True) != objects or not objects.is_dir()
            or (objects / 'info/alternates').exists()):
        raise ValueError('archive-local:unsupported-base-store')
    if b'\n' in os.fsencode(objects) or b'\r' in os.fsencode(objects):
        raise ValueError('archive-local:unsupported-base-store')
    return objects


def verify_local(archive, manifest):
    """The base is a retained dependency; only the archive's new objects are audited."""
    saved = manifest.get('source_fingerprint', {})
    if (manifest.get('capture_policy') != 'git-only'
            or saved.get('schema') not in (2, 3, 4)
            or manifest.get('git_admin_policy')):
        raise ValueError('archive-local:unsupported-policy; source retained')
    base, head = manifest['base_sha'], manifest['head_sha']
    if not all(re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', oid)
               for oid in (base, head)):
        raise ValueError('archive-local:invalid-object-id')
    common = Path(manifest['source_git_common_dir'])
    objects = base_objects(common)
    git(common, 'cat-file', '-e', base + '^{commit}')
    with tempfile.TemporaryDirectory(
        prefix='.verify-local-', dir=archive.parent,
    ) as name:
        scratch = Path(name)
        object_format = 'sha256' if len(head) == 64 else 'sha1'
        git(scratch, 'init', '--bare', '--quiet', '--object-format=' + object_format)
        (scratch / 'objects/info/alternates').write_bytes(os.fsencode(objects) + b'\n')
        git(scratch, 'update-ref', 'refs/archive/base', base)
        archived = imported_objects(scratch, archive)
        roots = payload_roots(scratch, archive, manifest)
        if not manifest.get('self_contained'):
            roots.append('^' + base)
        closure = git(scratch, 'rev-list', '--objects', '--no-object-names',
                      '--stdin', data=('\n'.join(roots) + '\n').encode())
        required = set(closure.splitlines())
        # Source alternates must not conceal an omitted unique commit/blob.
        if not required.issubset(archived):
            raise ValueError('archive-local:missing-unique-objects')
