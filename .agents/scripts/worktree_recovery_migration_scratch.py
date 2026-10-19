#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Reserved restore scratch, used only while the migration operation lock is held.

Private randomized directories are not user workspaces. All cooperating writers
must inherit the operation lock. Quarantine closes the old restore pathname before
the final identity/content check; mismatches are retained, never forced away.
"""

import os
from pathlib import Path
import shutil
import tempfile
import uuid

from worktree_archive_snapshot import git, snapshot
from worktree_lifetime_archive import inode, require
from worktree_recovery_migration_state import publish, sync_directory
from worktree_recovery_retirement_transaction import fingerprint


def slot_path(directory, record, key):
    name = record[key]
    require(Path(name).name == name and name.startswith((".restore-", ".cleanup-")),
            "migration:unsafe-scratch-name")
    return directory / name


def checked_target(slot, record):
    require(slot == slot.resolve(strict=True) and inode(slot) == record["restore_slot_inode"],
            "migration:scratch-container-changed")
    require({entry.name for entry in slot.iterdir()} <= {"worktree"},
            "migration:unexpected-scratch-entry")
    return slot / "worktree"


def prepare_restore(directory, record):
    if "restore_slot" not in record:
        extras = [entry for entry in directory.iterdir()
                  if entry.name not in {"journal.json", "lock"} and not entry.name.startswith(".journal-")]
        require(not extras, "migration:unowned-scratch; retained for review")
        slot = Path(tempfile.mkdtemp(prefix=".restore-", dir=directory))
        sync_directory(slot)
        record.update(restore_slot=slot.name, restore_slot_inode=inode(slot))
        # The newly created private container is owned before any clone starts.
        publish(directory / "journal.json", record)
    return checked_target(slot_path(directory, record, "restore_slot"), record)


def verify_restore(restored, record):
    require(restored == restored.resolve(strict=True)
            and (restored / ".git").is_dir() and not (restored / ".git").is_symlink(),
            "migration:unsafe-restore")
    common = Path(os.fsdecode(git(restored, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()))
    require(common == restored / ".git" and not os.path.lexists(common / "objects/info/alternates"),
            "migration:restore-borrows-source")
    git(restored, "fsck", "--full", "--no-progress", "--no-dangling")
    require(snapshot(restored, preserve_git_admin=True, include_ignored=True) == record["source"]["snapshot"],
            "migration:scratch-changed; retained for review")
    # New producers seal every physical entry, including unreachable Git objects.
    # Existing migration receipts retain their historical compatibility contract.
    if "restore_fingerprint" in record:
        require(fingerprint(restored) == record["restore_fingerprint"],
                "migration:scratch-content-drift; retained for review")


def prepare_cleanup(directory, record):
    slot = slot_path(directory, record, "restore_slot")
    restored = checked_target(slot, record)
    require(inode(restored) == record["restore_inode"], "migration:scratch-identity-changed")
    verify_restore(restored, record)
    record.update(phase="cleanup-pending", cleanup_slot=".cleanup-" + uuid.uuid4().hex)
    publish(directory / "journal.json", record)


def finish_scratch(directory, record):
    if record["phase"] == "restore-verified":
        prepare_cleanup(directory, record)
    source = slot_path(directory, record, "restore_slot")
    quarantined = slot_path(directory, record, "cleanup_slot")
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        observed = os.fstat(descriptor)
        require(f"{observed.st_dev}:{observed.st_ino}" == record["directory_inode"],
                "migration:journal-directory-changed")
        if os.path.lexists(source):
            require(not os.path.lexists(quarantined), "migration:conflicting-scratch-quarantine")
            os.rename(source.name, quarantined.name, src_dir_fd=descriptor, dst_dir_fd=descriptor)
            os.fsync(descriptor)
        if os.path.lexists(quarantined):
            restored = checked_target(quarantined, record)
            require(inode(restored) == record["restore_inode"], "migration:scratch-identity-changed")
            verify_restore(restored, record)
            require(shutil.rmtree.avoids_symlink_attacks, "migration:safe-scratch-cleanup-unavailable")
            shutil.rmtree(quarantined.name, dir_fd=descriptor)
            os.fsync(descriptor)
    finally:
        os.close(descriptor)
