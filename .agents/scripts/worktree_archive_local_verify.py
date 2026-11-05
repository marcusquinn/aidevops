#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Verify Git-only deltas against their retained local base without checkout."""

import hashlib
import json
import os
from pathlib import Path
import re

from worktree_archive_git import git
from worktree_archive_scratch import LOCAL_PREFIX, verification_scratch
from worktree_archive_auto_merge import verify_auto_merge
from worktree_archive_merge_objects import merge_roots, verify_merge_objects
from worktree_archive_objects import dependency_commit


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
    from worktree_archive_deletions import OPTIONS, load, remove

    head = manifest['head_sha']
    git(scratch, 'read-tree', head)
    staged = (archive / 'staged.patch').read_bytes()
    unstaged = (archive / 'diff.patch').read_bytes()
    compact = manifest.get('deletion_policy') == 'compact-v1'
    deletions = load(archive) if compact else None
    if compact:
        remove(scratch, deletions['staged'], index_only=True)
    if staged:
        git(scratch, 'apply', '--cached', str(archive / 'staged.patch'))
    index = git(scratch, 'ls-files', '--stage', '-z')
    if compact:
        # Preserve the existing fingerprint contract for old receipts/readers.
        # Expanded diffs exist only in memory, never in the archive payload.
        staged = git(scratch, 'diff', '--cached', *OPTIONS, head)
        staged_tree = git(scratch, 'write-tree').strip().decode('ascii')
        remove(scratch, deletions['unstaged'], index_only=True)
        if unstaged:
            git(scratch, 'apply', '--cached', str(archive / 'diff.patch'))
        unstaged = git(scratch, 'diff', '--cached', *OPTIONS, staged_tree)
    values = [head, hashlib.sha256(index).hexdigest(),
              hashlib.sha256(staged).hexdigest(), hashlib.sha256(unstaged).hexdigest()]
    digest = hashlib.sha256(json.dumps(values).encode('ascii')).hexdigest()
    saved = manifest['source_fingerprint']
    if saved.get('head') != head or saved.get('sha256') != digest:
        raise ValueError('archive-local:patch-or-index-mismatch')
    if unstaged and not compact:
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


def require_published_head(common, head):
    """A bundle-less published archive is only as durable as its remote ref.

    GH#36607: local verification gates source removal, so the omitted commits
    must still be complete in the retained store and reachable from a
    origin remote-tracking ref; a dangling or partially pruned graph is refused.
    """
    graph = git(common, 'rev-list', '--objects', '--no-object-names', '--missing=print', head)
    if any(line.startswith(b'?') for line in graph.splitlines()):
        raise ValueError('archive-local:published-head-incomplete; source retained')
    if not git(common, 'for-each-ref', '--count=1', '--contains', head,
               '--format=%(refname)', 'refs/remotes/origin/').strip():
        raise ValueError('archive-local:published-head-not-on-remote; source retained')


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
    dependency = dependency_commit(manifest)
    if dependency != base:
        require_published_head(common, dependency)
    # Same liveness-fenced scratch as full verification (GH#36468): a killed
    # caller cannot leave an unreclaimable copy beside the archive.
    with verification_scratch(archive, LOCAL_PREFIX) as scratch:
        object_format = 'sha256' if len(head) == 64 else 'sha1'
        git(scratch, 'init', '--bare', '--quiet', '--object-format=' + object_format)
        (scratch / 'objects/info/alternates').write_bytes(os.fsencode(objects) + b'\n')
        git(scratch, 'update-ref', 'refs/archive/base', base)
        archived = imported_objects(scratch, archive)
        roots = payload_roots(scratch, archive, manifest)
        if not manifest.get('self_contained'):
            roots.append('^' + dependency)
        closure = git(scratch, 'rev-list', '--objects', '--no-object-names',
                      '--stdin', data=('\n'.join(roots) + '\n').encode())
        required = set(closure.splitlines())
        # Explicit tree roots can traverse dependency-covered objects even with
        # ^dependency. Only that exact retained graph may replace bundle payload.
        if not required.issubset(archived) and not manifest.get('self_contained'):
            covered = git(scratch, 'rev-list', '--objects', '--no-object-names', dependency)
            required.difference_update(covered.splitlines())
        # Source alternates must not conceal an omitted unique commit/blob.
        if not required.issubset(archived):
            raise ValueError('archive-local:missing-unique-objects')
