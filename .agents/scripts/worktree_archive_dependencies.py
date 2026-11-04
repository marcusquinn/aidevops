#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Inspect, seal and import Git object dependencies for archive restoration."""

import subprocess  # nosec B404 -- exception classification only

from worktree_archive_administration import git


def object_store_files(objects):
    """Traverse dependency files without accepting symlinked store entries."""
    from worktree_lifetime_archive import require
    pending = [objects]
    while pending:
        path = pending.pop()
        require(not path.is_symlink(), "restore-proof:symlinked-object-store")
        if path.is_dir():
            pending.extend(path.iterdir())
        else:
            yield path


def object_present(common, oid):
    """Report whether a commit and its full graph exist in the source store."""
    try:
        graph = git(common, "rev-list", "--objects", "--no-object-names", "--missing=print", oid)
    except subprocess.CalledProcessError:
        return False
    return not any(line.startswith(b"?") for line in graph.splitlines())


def import_published_head(target, common, head):
    """Fetch the published head into the owned target with explicit origin consent."""
    from worktree_archive_base_source import MISSING_PROMISOR_BASE, authorized_base_source
    from worktree_archive_git import base_import_timeout, base_upload_pack
    try:
        source, protocol = authorized_base_source(target, common, git)
        git(target, "-c", "protocol.allow=never", "-c", f"protocol.{protocol}.allow=always",
            "-c", "http.followRedirects=false", "-c", f"http.{source}.followRedirects=false",
            "fetch", "--quiet", "--no-tags", "--no-auto-maintenance", "--no-write-fetch-head",
            "--refetch", "--upload-pack=" + base_upload_pack(), source, head, timeout=base_import_timeout())
        git(target, "cat-file", "-e", head + "^{commit}")
        if not object_present(target, head):
            raise ValueError(MISSING_PROMISOR_BASE)
    except (ValueError, subprocess.CalledProcessError):
        raise ValueError(MISSING_PROMISOR_BASE) from None
