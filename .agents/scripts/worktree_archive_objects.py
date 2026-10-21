#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Select and validate existing archive dependencies without changing Git state."""

from pathlib import Path
import re
import tempfile

from worktree_archive_administration import (
    auto_merge_oid, fetch_head_roots, git, load_administration,
)
from worktree_archive_auto_merge import (
    capture_auto_merge as capture_auto_merge, verify_auto_merge,
)


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
    if manifest.get('git_admin_policy') is not None:
        verify_administration(archive, scratch, manifest)
    elif manifest.get('capture_policy') == 'git-only':
        if bundle.is_file():
            if manifest.get('source_fingerprint', {}).get('auto_merge') is not None:
                fetch_preservation(scratch, archive)
            else:
                git(scratch, 'fetch', '--quiet', '--no-write-fetch-head', str(bundle), 'HEAD:refs/archive/head')
        git(scratch, 'cat-file', '-e', manifest['head_sha'] + '^{commit}')
        verify_auto_merge(scratch, archive, manifest)


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
        with tempfile.TemporaryDirectory(prefix='.archive-verify-', dir=archive.parent) as temporary:
            verify_object_graph(archive, Path(temporary), manifest)
    elif bundle.exists():
        common = Path(manifest.get('source_git_common_dir', ''))
        root = common if common.is_dir() else archive
        git(root, 'bundle', 'verify', str(bundle))
