#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fingerprint Git-only archive contents without restoring or changing them."""

import hashlib
import json
import os
from pathlib import Path

from worktree_archive_git import git
from worktree_archive_index import git_index_state
from worktree_archive_state import auto_merge, merge_digest
from worktree_archive_untracked import untracked_contents


def git_snapshot(path, patches=None, metadata=None, include_untracked=True):
    """Describe Git changes and ordinary untracked files, excluding Git-ignored files.

    Capture passes its already-written patches, so describing the archive does
    not repeat diffs or verify restoration. Comparison is a separate operation.
    """
    root = Path(path).resolve(strict=True)
    # The legacy admission record is preserved only by preserve-v1's git-admin.json.
    # Guard this policy boundary even with cached metadata or a structured merge;
    # git_index_state is also used independently of the archive capture policy.
    # The profile publication record is deliberately excluded: profile-readme
    # recovery retires completed publication worktrees through Git-only capture.
    admin = Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n')))
    for name in ('aidevops/js-admission.json',):
        if os.path.lexists(admin / name):
            raise ValueError(f'git_admin:requires_preservation:{name}')
    metadata = metadata if metadata is not None else git_index_state(root)
    if 'merge' in metadata:
        state = metadata['merge']
        result = {'schema': 4, 'policy': 'git-only', 'head': state['head'],
                  'files': len(state['working']), 'bytes': sum(len(value[1]) // 2 for value in state['working'].values() if value),
                  'merge_sha256': merge_digest(state)}
        if include_untracked:
            paths = sorted(filter(None, git(root, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0')))
            contents = untracked_contents(root, paths)
            result.update(untracked_files=len(paths), untracked_symlink_modes=True,
                          untracked_sha256=hashlib.sha256(json.dumps(contents, ensure_ascii=True).encode('ascii')).hexdigest())
        return result
    # Scratch verification must not inherit source-local rename/order settings.
    from worktree_archive_deletions import OPTIONS as options

    staged = (patches / "staged.patch").read_bytes() if patches else git(root, "diff", "--cached", *options)
    unstaged = (patches / "diff.patch").read_bytes() if patches else git(root, "diff", *options)
    head = metadata["head"]
    values = [head, metadata["index"],
              hashlib.sha256(staged).hexdigest(), hashlib.sha256(unstaged).hexdigest()]
    result = {"schema": 2, "policy": "git-only", "head": head, "files": metadata["files"],
               "bytes": len(staged) + len(unstaged),
               "sha256": hashlib.sha256(json.dumps(values).encode("ascii")).hexdigest()}
    oid = auto_merge(root)
    if oid is not None:
        result['auto_merge'] = oid
    # GH#36883: bind preserved runtime-local config so source-matches blocks
    # retirement when it appears, changes or disappears after capture.
    from worktree_archive_runtime_config import fingerprint_fields
    result.update(fingerprint_fields(root, admin))
    if include_untracked:
        paths = sorted(filter(None, git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")))
        size = sum((root / os.fsdecode(raw)).lstat().st_size for raw in paths)
        if (len(paths) > int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES", "10000"))
                or size > int(os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES", "1073741824"))):
            raise ValueError("untracked payload exceeds configured limit")
        contents = untracked_contents(root, paths)
        result.update(schema=3, untracked_files=len(paths), bytes=result["bytes"] + size,
                      untracked_symlink_modes=True,
                      untracked_sha256=hashlib.sha256(json.dumps(contents, ensure_ascii=True).encode("ascii")).hexdigest())
    return result
