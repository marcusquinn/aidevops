#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Check whether a worktree's Git state is supported by archival."""

from worktree_archive_administration import administration, git, git_dirs
from worktree_archive_auto_merge import auto_merge as auto_merge
from worktree_archive_history import supported_history as supported_history
from worktree_archive_merge_capture import (
    capture_merge as capture_merge, load_merge as load_merge,
    merge_digest as merge_digest, merge_pending as merge_pending,
    merge_state as merge_state, validate_merge as validate_merge,
)
from worktree_archive_merge_objects import verify_merge_objects as verify_merge_objects
from worktree_archive_merge_restore import restore_merge as restore_merge

# Git records every intent-to-add index entry with the empty-blob OID.
EMPTY_BLOBS = frozenset((b"e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
                         b"473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"))


def tagged_index(root):
    """Return (tags, `ls-files --stage` bytes) from one `ls-files -v --stage` read.

    Each entry is a one-letter `-v` tag, a space and the exact `--stage` entry,
    so one spawn yields both views byte for byte (the index digest is unchanged).
    """
    entries = [entry for entry in git(root, "ls-files", "-v", "--stage", "-z").split(b"\0") if entry]
    if any(entry[1:2] != b" " for entry in entries):
        raise ValueError("unexpected Git index listing")
    return [entry[:1] for entry in entries], b"".join(entry[2:] + b"\0" for entry in entries)


def intent_to_add_differs(root, index, *, strict):
    """Compare both intent-to-add views of this pass's index read.

    ls-files --stage cannot distinguish intent-to-add from a staged empty blob.
    Without any empty-blob entry there is no intent-to-add entry, so both views
    are equal and neither is read. Otherwise each caller keeps its verdict:
    strict (Git-only capture) always compares, because an intent-to-add entry for
    a file HEAD holds as an empty blob is visible-empty but invisible-deleted;
    non-strict (supported_state) treats an empty visible view as equality.
    """
    if not any(entry.split(b"\t", 1)[0].split()[1] in EMPTY_BLOBS for entry in index.split(b"\0") if entry):
        return False
    options = ("--cached", "--raw", "-z", "--no-ext-diff") + (("--no-color",) if strict else ())
    visible = git(root, "diff", *options, "--ita-visible-in-index")
    if not visible and not strict:
        return False
    return visible != git(root, "diff", *options, "--ita-invisible-in-index")


def inventories(root, include_ignored=False, *, index=None, untracked=True):
    """Return (index, paths) after the Git-filter/LFS guard.

    untracked=False runs only the guard and returns tracked paths, for callers
    that discard the path list and list untracked files themselves.
    """
    if index is None:
        index = git(root, "ls-files", "--stage", "-z")
    paths = set()
    for entry in index.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, _, stage = metadata.split()
        if stage != b"0" or mode not in (b"100644", b"100755", b"120000"):
            raise ValueError("submodules or unmerged entries require separate preservation")
        paths.add(path)
    attributes = git(root, "check-attr", "-z", "--stdin", "filter", data=b"\0".join(sorted(paths)) + b"\0") if paths else b""
    fields = attributes.split(b"\0")
    if any(value not in (b"unspecified", b"unset") for value in fields[2::3]):
        raise ValueError("Git filters, including local LFS payloads, require separate preservation")
    if not untracked:
        return index, sorted(paths)
    excludes = () if include_ignored else ("--exclude-standard",)
    paths.update(path for path in git(root, "ls-files", "--others", *excludes, "-z").split(b"\0") if path)
    return index, sorted(paths)


def supported_state(root, preserve_git_admin=False, include_ignored=False):
    admin, common = git_dirs(root)
    if preserve_git_admin:
        administration(root, dirs=(admin, common))
    pending = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
               "rebase-merge", "rebase-apply", "sequencer", "BISECT_LOG", "index.lock", "config.worktree", "SQUASH_MSG")
    if not preserve_git_admin and any((admin / name).exists() for name in pending):
        raise ValueError("unfinished Git operation is not supported for automatic archival")
    if not preserve_git_admin:
        supported_administration(root, admin, common)
    if git(root, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ValueError("shallow history is not self-contained")
    if not include_ignored and git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"):
        raise ValueError("ignored content requires a separate preservation decision")
    tags, index = tagged_index(root)
    if any(tag != b"H" for tag in tags):
        raise ValueError("special index flags or unmerged entries are unsupported")
    # Preserved administration keeps the index itself, intent-to-add flags included.
    if not preserve_git_admin and intent_to_add_differs(root, index, strict=False):
        raise ValueError("intent-to-add index entries require separate preservation")
    if not preserve_git_admin:
        supported_history(root, admin)


def supported_administration(root, admin, common=None):
    if auto_merge(root, admin) is not None:
        raise ValueError('AUTO_MERGE requires the unified metadata preservation path')
    if common is None:
        common = git_dirs(root)[1]
    if admin.resolve() == common.resolve():
        # Independent restores are full repositories. Managed source enrollment
        # separately refuses canonical repositories; only linked admin is removed.
        return
    allowed = {"HEAD", "index", "commondir", "gitdir", "ORIG_HEAD", "COMMIT_EDITMSG", "logs", "refs"}
    for entry in admin.iterdir():
        if entry.name not in allowed or entry.is_symlink():
            raise ValueError(f"unknown Git administrative state requires separate preservation: {entry.name!r}")
        if entry.name == "logs":
            if not entry.is_dir() or any(child.name != "HEAD" or child.is_symlink()
                                         or not child.is_file() for child in entry.iterdir()):
                raise ValueError("unknown Git administrative log requires separate preservation")
        elif entry.name == "refs":
            # Recent Git creates this empty directory for a new linked worktree.
            if not entry.is_dir() or any(entry.iterdir()):
                raise ValueError("private Git references require separate preservation")
        elif not entry.is_file():
            raise ValueError("unsupported Git administrative entry")
