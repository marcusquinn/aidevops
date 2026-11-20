#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate that a Git index and worktree can be represented by two patches."""

import hashlib
import os
from pathlib import Path
import re

from worktree_archive_administration import administration, git
from worktree_archive_filesystem import supported_git_metadata
from worktree_archive_state import intent_to_add_differs, inventories, supported_history, tagged_index

SHARED_INDEX = re.compile(rb'/.*/sharedindex\.(?:[0-9a-f]{40}|[0-9a-f]{64})')


def archive_policies(manifest):
    """Validate policy declarations for explicit verification, not capture."""
    if not isinstance(manifest.get('include_ignored', False), bool):
        raise SystemExit('invalid ignored capture policy')
    capture_policy = manifest.get('capture_policy')
    if capture_policy not in (None, 'git-only'):
        raise SystemExit('unknown capture policy')
    if capture_policy == 'git-only' and (manifest.get('include_ignored') or manifest.get('git_admin_policy')):
        raise SystemExit('inconsistent Git-only policy')
    if capture_policy == 'git-only' and manifest.get('source_fingerprint', {}).get('schema') not in (2, 3, 4):
        raise SystemExit('unsupported Git changes fingerprint')
    merge = manifest.get('merge_policy')
    schema = manifest.get('source_fingerprint', {}).get('schema')
    if merge is not None or schema == 4:
        expected = (merge == 'structured-v1', capture_policy == 'git-only', schema == 4,
                    manifest.get('self_contained') is True)
        if not all(expected):
            raise SystemExit('invalid required merge policy')
    policy = manifest.get('git_admin_policy')
    if policy is not None and (policy != 'preserve-v1' or not isinstance(manifest.get('self_contained'), bool)):
        raise SystemExit('invalid Git administration policy')
    return capture_policy, policy


def index_dirs(root):
    """Resolve (admin, common, index.lock, split-index probe) in one spawn for one capture pass."""
    # --absolute-git-dir is absolute before the --path-format switch.
    # --shared-index-path prints nothing outside split-index mode, so it stays last.
    lines = git(root, 'rev-parse', '--absolute-git-dir', '--path-format=absolute', '--git-common-dir',
                '--git-path', 'index.lock', '--shared-index-path').rstrip(b'\n').split(b'\n')
    # A newline inside a path must not shift fields: an optional fourth line is
    # accepted only as a shared index file, never as a displaced index.lock path.
    if len(lines) not in (3, 4) or (len(lines) == 4 and not SHARED_INDEX.fullmatch(lines[3])):
        raise ValueError('unexpected Git directory resolution')
    admin_raw, common_raw, lock = (os.fsdecode(line) for line in lines[:3])
    return Path(admin_raw), Path(common_raw), lock, b''.join(lines[3:])


def git_index_state(path, head=None, dirs=None):
    root = Path(path).resolve(strict=True)
    # A caller may pass directories it resolved moments earlier in the same pass.
    admin, common, lock, shared_index = dirs if dirs is not None else index_dirs(root)
    if os.path.lexists(lock):
        raise ValueError('git_admin:index_locked:index.lock')
    from worktree_archive_state import merge_pending, merge_state
    if merge_pending(root, admin=admin):
        state = merge_state(root, admin, common)
        return {'head': state['head'], 'merge': state}
    # One read yields both the --stage bytes (digest below) and the -v flags.
    tags, index = tagged_index(root)
    entries = [entry.split(b"\t", 1) for entry in index.split(b"\0") if entry]
    if any(metadata.split()[2] != b"0" for metadata, _ in entries):
        raise ValueError("unmerged index cannot be represented by two patches")
    if any(metadata.split()[0] == b"160000" for metadata, _ in entries):
        raise ValueError("submodule contents cannot be represented by two patches")
    supported_git_metadata(root, (path for _, path in entries))
    if any(tag == b"S" or tag.islower() for tag in tags):
        raise ValueError("index has skip-worktree/assume-unchanged entries")
    # Index-only metadata reads, not a working-tree scan or restore verification.
    if intent_to_add_differs(root, index, strict=True):
        raise ValueError("intent-to-add index entries cannot be represented by two patches")
    # Git-only preserves current HEAD, not abandoned reflog/previous-HEAD history.
    # Unknown administration, unique drafts and interrupted operations still need
    # preservation. Structured merges returned above preserve required ORIG_HEAD.
    state = administration(root, dirs=(admin, common, shared_index))
    if state['files'].get('config.worktree'):
        # GH#36883: only known runtime-local keys are preserved (as bytes, never
        # restored); unknown, mixed or comment-only configuration is refused.
        from worktree_archive_runtime_config import classify
        classify(root, admin)
    if (admin / 'SQUASH_MSG').exists():
        raise ValueError('uncommitted squash draft requires separate preservation')
    # administration() listed the same private prefixes in this pass.
    supported_history(root, admin, require_reachable_history=False, private_refs=list(state['refs']))
    # Retain the Git-filter/LFS preservation guard; git_snapshot lists untracked files itself.
    inventories(root, index=index, untracked=False)
    return {"head": head or git(root, "rev-parse", "--verify", "HEAD").strip().decode("ascii"),
            "index": hashlib.sha256(index).hexdigest(), "files": len(entries)}
