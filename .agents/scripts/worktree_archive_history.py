#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Reject Git history that automatic archives cannot preserve."""

from worktree_archive_administration import git


def supported_history(root, admin, require_reachable_history=True):
    if require_reachable_history:
        revisions = git(root, "reflog", "show", "--format=%H", "HEAD")
        previous = admin / "ORIG_HEAD"
        if previous.exists():
            if previous.is_symlink():
                raise ValueError("symlinked Git administrative state")
            revisions += previous.read_bytes() + b"\n"
        # rev-list stops at blank lines; normalize before the exclusion.
        revisions = b"\n".join(line for line in revisions.splitlines() if line) + b"\n^HEAD\n"
        if git(root, "rev-list", "--max-count=1", "--stdin", data=revisions):
            raise ValueError("git_admin:unpreserved_history; reflog-only or previous HEAD history requires separate preservation")
    if git(root, "for-each-ref", "--format=%(refname)", "refs/worktree/", "refs/bisect/", "refs/rewritten/"):
        raise ValueError("private worktree refs require separate preservation")
    # COMMIT_EDITMSG is disposable editor metadata, not working/index state or
    # unique history. Ordinary archives neither preserve it nor require it to
    # match a committed message. Never modify the live administrative file.
