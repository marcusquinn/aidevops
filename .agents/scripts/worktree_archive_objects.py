#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Select and validate existing archive dependencies without changing Git state."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
from worktree_recovery_timing import timed
from worktree_archive_git import MISSING_PROMISOR_BASE, RETAINED_VERIFICATION_SCRATCH

from worktree_archive_administration import (
    auto_merge_oid, fetch_head_roots, git, load_administration,
)
from worktree_archive_auto_merge import (
    capture_auto_merge as capture_auto_merge, verify_auto_merge,
)


def require_independent_base_receiver(root, common, run_git):
    """Refuse shared stores and alternates before any base-object import."""
    admin = run_git(root, 'rev-parse', '--absolute-git-dir').strip()
    receiver = run_git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()
    receiver_path = Path(os.fsdecode(receiver)).resolve()
    if (Path(os.fsdecode(admin)).resolve() != receiver_path or receiver_path == common.resolve()
            or os.path.lexists(receiver_path / 'objects/info/alternates')):
        raise ValueError('git_admin:base_import_requires_independent_scratch')


def base_graph_missing(root, base, run_git):
    """Inspect the full recorded graph through the caller's bounded Git policy."""
    graph = run_git(root, 'rev-list', '--objects', '--no-object-names', '--missing=print', base)
    return any(line.startswith(b'?') for line in graph.splitlines())


def verify_imported_base(root, base, run_git):
    """Require complete independent objects, not just successful transfer."""
    if base_graph_missing(root, base, run_git):
        raise ValueError(MISSING_PROMISOR_BASE)
    run_git(root, 'fsck', '--full', '--no-reflogs', base)


def index_roots(root):
    """Include staged and resolve-undo objects, excluding null object IDs."""
    roots = set()
    for inventory in ('--stage', '--resolve-undo'):
        for entry in git(root, "ls-files", inventory, "-z").split(b"\0"):
            if entry:
                oid = entry.split(b"\t", 1)[0].split()[1]
                if set(oid) != {48}:
                    roots.add(oid.decode("ascii"))
    return roots


def administration_roots(root, state, include_index=True):
    """Return validated dependencies; verification includes the entire index."""
    roots = {git(root, "rev-parse", "HEAD").strip().decode("ascii")}
    roots.update(state["refs"].values())
    roots.update(fetch_head_roots(state["files"].get("FETCH_HEAD", "")))
    for name, encoded in state["files"].items():
        data = bytes.fromhex(encoded)
        if name == "logs/HEAD":
            for line in data.splitlines():
                roots.update(part.decode("ascii") for part in line.split()[:2] if set(part) != {48})
        elif name == "ORIG_HEAD":
            roots.add(data.strip().decode("ascii"))
        elif name == "AUTO_MERGE":
            roots.add(auto_merge_oid(data))
    if include_index:
        roots.update(index_roots(root))
    for oid in roots:
        if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid):
            raise ValueError("git_admin:invalid_object_id")
    return sorted(roots)


def bundle_roots(root, state):
    """Add index dependencies only when the required history does not cover them."""
    history = administration_roots(root, state, include_index=False)
    extra = set(administration_roots(root, state)) - set(history)
    if extra:
        reachable = git(root, 'rev-list', '--objects', '--no-object-names', '--stdin',
                        data=('\n'.join(history) + '\n').encode('ascii'))
        extra.difference_update(oid.decode('ascii') for oid in reachable.splitlines())
    return sorted(set(history) | extra)


def verify_object_graph(archive, scratch, manifest):
    # Load restoration helpers only at verification time; snapshot construction
    # also uses this module's dependency selectors.
    from worktree_archive_snapshot import fetch_preservation, seed_base, verify_administration
    bundle = archive / 'commits.bundle'
    object_format = 'sha256' if len(manifest['head_sha']) == 64 else 'sha1'
    git(scratch, 'init', '--bare', '--quiet', '--object-format=' + object_format)
    if manifest.get('self_contained') is not True:
        seed_base(scratch, manifest)
    if bundle.is_file():
        git(scratch, 'bundle', 'verify', str(bundle))
    if manifest.get('merge_policy') == 'structured-v1':
        from worktree_archive_state import load_merge, verify_merge_objects
        state = load_merge(archive, manifest)
        fetch_preservation(scratch, archive)
        verify_merge_objects(scratch, state)
    elif manifest.get('git_admin_policy') is not None:
        verify_administration(archive, scratch, manifest)
    elif manifest.get('capture_policy') == 'git-only':
        if bundle.is_file():
            if manifest.get('source_fingerprint', {}).get('auto_merge') is not None:
                fetch_preservation(scratch, archive)
            else:
                git(scratch, 'fetch', '--quiet', '--no-write-fetch-head', str(bundle), 'HEAD:refs/archive/head')
        git(scratch, 'cat-file', '-e', manifest['head_sha'] + '^{commit}')
        verify_auto_merge(scratch, archive, manifest)


def verify_in_scratch(archive, manifest):
    # The exclusive directory is also the per-archive retry fence. A failure or
    # cancellation leaves it in place; never reuse or retire prior evidence.
    archive = archive.resolve(strict=True)
    key = hashlib.sha256(os.fsencode(archive)).hexdigest()
    scratch = archive.parent / ('.archive-verify-' + key)
    try:
        scratch.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ValueError(RETAINED_VERIFICATION_SCRATCH) from error
    created = scratch.lstat()
    verify_object_graph(archive, scratch, manifest)
    observed = scratch.lstat()
    if (not stat.S_ISDIR(observed.st_mode)
            or (observed.st_dev, observed.st_ino) != (created.st_dev, created.st_ino)):
        raise ValueError('archive-verify:scratch-identity-changed; evidence retained')
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('archive-verify:safe-cleanup-unavailable; evidence retained')
    shutil.rmtree(scratch)


@timed("git-object-preparation")
def verify_git_objects(archive, manifest):
    """Verify against the recorded base graph, retaining legacy bundle readers."""
    from worktree_archive_snapshot import archive_policies
    capture_policy, policy = archive_policies(manifest)
    bundle = archive / 'commits.bundle'
    if policy is not None:
        load_administration(archive)
    if manifest.get('self_contained') is True or policy is not None or capture_policy == 'git-only':
        if manifest.get('self_contained') is True and not bundle.is_file():
            raise ValueError('self-contained archive requires a bundle')
        verify_in_scratch(archive, manifest)
    elif bundle.exists():
        common = Path(manifest.get('source_git_common_dir', ''))
        root = common if common.is_dir() else archive
        git(root, 'bundle', 'verify', str(bundle))
