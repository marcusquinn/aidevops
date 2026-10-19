#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Select and validate existing archive dependencies without changing Git state."""

import re

from worktree_archive_administration import fetch_head_roots, git


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
