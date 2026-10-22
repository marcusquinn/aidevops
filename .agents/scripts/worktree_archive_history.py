#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Reject Git history and draft state that automatic archives cannot preserve."""

import os

from worktree_archive_administration import git


def supported_message(root, message):
    if not message.exists():
        return
    if message.is_symlink():
        raise ValueError("uncommitted message draft requires separate preservation")
    draft = message.read_bytes().rstrip(b"\n")
    if draft != git(root, "log", "-1", "--format=%B").rstrip(b"\n"):
        # Switching branches or merging can leave a previously committed
        # message here. Accept only an exact message in the archived ancestry.
        committed = git(root, "log", "-1", "--format=%B", "--fixed-strings",
                        "--grep=" + os.fsdecode(draft), "HEAD").rstrip(b"\n")
        if not draft or committed != draft:
            raise ValueError("uncommitted message draft requires separate preservation")


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
    supported_message(root, admin / "COMMIT_EDITMSG")
