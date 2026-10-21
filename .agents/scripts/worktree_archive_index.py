#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate that a Git index and worktree can be represented by two patches."""

import hashlib
import os
from pathlib import Path

from worktree_archive_administration import administration, git
from worktree_archive_filesystem import supported_git_metadata
from worktree_archive_state import inventories, supported_history


def archive_policies(manifest):
    """Validate policy declarations for explicit verification, not capture."""
    if not isinstance(manifest.get('include_ignored', False), bool):
        raise SystemExit('invalid ignored capture policy')
    capture_policy = manifest.get('capture_policy')
    if capture_policy not in (None, 'git-only'):
        raise SystemExit('unknown capture policy')
    if capture_policy == 'git-only' and (manifest.get('include_ignored') or manifest.get('git_admin_policy')):
        raise SystemExit('inconsistent Git-only policy')
    if capture_policy == 'git-only' and manifest.get('source_fingerprint', {}).get('schema') not in (2, 3):
        raise SystemExit('unsupported Git changes fingerprint')
    policy = manifest.get('git_admin_policy')
    if policy is not None and (policy != 'preserve-v1' or not isinstance(manifest.get('self_contained'), bool)):
        raise SystemExit('invalid Git administration policy')
    return capture_policy, policy


def git_index_state(path, head=None):
    root = Path(path).resolve(strict=True)
    lock = os.fsdecode(git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index.lock').rstrip(b'\n'))
    if os.path.lexists(lock):
        raise ValueError('git_admin:index_locked:index.lock')
    index = git(root, "ls-files", "--stage", "-z")
    entries = [entry.split(b"\t", 1) for entry in index.split(b"\0") if entry]
    if any(metadata.split()[2] != b"0" for metadata, _ in entries):
        raise ValueError("unmerged index cannot be represented by two patches")
    if any(metadata.split()[0] == b"160000" for metadata, _ in entries):
        raise ValueError("submodule contents cannot be represented by two patches")
    supported_git_metadata(root, (path for _, path in entries))
    flags = git(root, "ls-files", "-v", "-z").split(b"\0")
    if any(entry[:1] == b"S" or entry[:1].islower() for entry in flags if entry):
        raise ValueError("index has skip-worktree/assume-unchanged entries")
    # Index-only metadata reads, not a working-tree scan or restore verification.
    options = ("--cached", "--raw", "-z", "--no-ext-diff", "--no-color")
    if git(root, "diff", *options, "--ita-visible-in-index") != git(root, "diff", *options, "--ita-invisible-in-index"):
        raise ValueError("intent-to-add index entries cannot be represented by two patches")
    # Not copying raw administration does not authorize losing unique drafts,
    # interrupted operations or commits reachable only through a worktree reflog.
    administration(root)
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    if (admin / 'SQUASH_MSG').exists():
        raise ValueError('uncommitted squash draft requires separate preservation')
    supported_history(root, admin)
    inventories(root)  # Reuse the existing Git-filter/LFS preservation guard.
    return {"head": head or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii"),
            "index": hashlib.sha256(index).hexdigest(), "files": len(entries)}
