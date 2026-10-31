#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed recovery of interrupted archive-verification scratch copies."""

import os
from pathlib import Path
import stat
import subprocess

from worktree_archive_administration import git
from worktree_archive_registration import LEGACY_TABLE, MANAGED_TABLE, REGISTRATION_SQL, legacy_registration


SPOTLIGHT_MARKER = ".metadata_never_index"


class UnsealedRecovery:
    """Recovery operations shared by canonical restoration proofs."""

    @staticmethod
    def framework_marker_only(target, status):
        """GH#36279: tolerate only the exclusions helper's own Spotlight marker.

        Older backfills touched it inside archive scratch slots. Accept a status
        that is exactly that ignored entry, and only for an empty, regular,
        non-symlink root file (the `_we_apply_spotlight` rule). Anything else,
        including any second entry, still retains the slot.
        """
        if status != b"!! " + SPOTLIGHT_MARKER.encode() + b"\n":
            return False
        try:
            observed = os.lstat(target / SPOTLIGHT_MARKER)
        except OSError:
            return False
        return stat.S_ISREG(observed.st_mode) and observed.st_size == 0 and observed.st_nlink == 1

    @staticmethod
    def unregistered_admin(target, common, unsealed):
        """Return the Git admin dir of a registry-less copy after Git proves identity."""
        from worktree_lifetime_archive import require

        def resolved(*args):
            return Path(os.fsdecode(git(target, *args)).rstrip("\n")).resolve(strict=True)

        try:
            require(resolved("rev-parse", "--show-toplevel") == target.resolve(strict=True), unsealed)
            require(resolved("rev-parse", "--path-format=absolute", "--git-common-dir") == common,
                    "restore-proof:wrong-base")
            admin = resolved("rev-parse", "--absolute-git-dir")
            require(admin.parent == common / "worktrees", unsealed)
        except (subprocess.SubprocessError, OSError):
            # Half-created copies remain protected with the same recovery text.
            raise ValueError(unsealed) from None
        return admin

    @staticmethod
    def recover_unsealed(directory, receipt, save, record, common):
        """GH#35957: reclaim a registered copy whose creation was never sealed.

        Before legacy-guards creation was accepted, macOS failed after Git and
        registry creation but before .creation.json, leaving a "restoring" slot
        that held a registered worktree. Remove it only when the slot inode,
        sole entry, legacy creation identity and Git common dir all match. A
        missing owner is accepted only for clean, ref-reachable scratch. Missing
        slots require absence of ownership and Git registration; historical
        creation records are left untouched because no deletion is needed.
        """
        from worktree_lifetime_archive import inode, managed_module, require, transaction
        slot = directory / receipt["slot"]
        target = slot / "worktree"
        require(common.is_absolute() and common == common.resolve(strict=True), "restore-proof:unsafe-base")
        changed = "restore-proof:slot-changed"
        require(Path(receipt["slot"]).name == receipt["slot"]
                and slot.parent == directory and slot.name.startswith(".restore-"), changed)
        unsealed = "restore-proof:unsealed-copy-retained; inspect owned scratch"
        require(directory == directory.resolve(strict=True), changed)
        if not os.path.lexists(slot):
            with transaction() as connection:
                require(connection.execute("SELECT 1 FROM worktree_owners WHERE worktree_path = ?",
                                           (str(target),)).fetchone() is None, unsealed)
                entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
                require(b"worktree " + os.fsencode(target) not in entries, unsealed)
                receipt["state"] = "cleaned"
                save(record)
            return
        require(slot == slot.resolve(strict=True), changed)
        require(inode(slot) == receipt["slot_inode"], changed)
        require({entry.name for entry in slot.iterdir()} == {"worktree"}, changed)
        require(target.is_dir() and not target.is_symlink(), changed)
        with transaction() as connection:
            owner = connection.execute("SELECT task_id, branch FROM worktree_owners WHERE worktree_path = ?",
                                       (str(target),)).fetchone()
            require(owner in (None, ("archive-verification:" + slot.name, "HEAD")), unsealed)
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                                  (MANAGED_TABLE,)).fetchone():
                require(connection.execute(REGISTRATION_SQL[MANAGED_TABLE][0], (str(target),)).fetchone() is None,
                        unsealed)
            registered = legacy_registration(connection, target)
            if registered is not None:
                # verify_identity recomputes path/admin/common from Git itself.
                managed_module().verify_identity(registered, target)
                require(registered["identity"]["common"] == str(common), "restore-proof:wrong-base")
                admin = Path(registered["identity"]["admin"])
            else:
                # GH#36205: an interrupted creation can leave a Git-registered
                # slot with no registry rows at all. Only a no-owner slot is
                # eligible, and Git itself must prove path/admin/common identity.
                require(owner is None, unsealed)
                admin = UnsealedRecovery.unregistered_admin(target, common, unsealed)
            index_entries = git(target, "ls-files", "-v", "-z").split(b"\0")
            require(not any(entry[:1] == b"S" or entry[:1].islower()
                            for entry in index_entries if entry), unsealed)
            status = git(target, "status", "--porcelain=v1", "--untracked-files=all", "--ignored")
            require(not status or UnsealedRecovery.framework_marker_only(target, status), unsealed)
            require(git(target, "for-each-ref", "--contains=HEAD", "--format=%(refname)").strip(), unsealed)
            entries = git(common, "worktree", "list", "--porcelain", "-z").split(b"\0")
            require(b"worktree " + os.fsencode(target) in entries, unsealed)
            repository = Path(os.fsdecode(next(entry[9:] for entry in entries if entry.startswith(b"worktree "))))
            git(repository, "worktree", "remove", "--force", str(target))
            require(not os.path.lexists(target) and not os.path.lexists(admin),
                    "restore-proof:administration-remains")
            connection.execute("DELETE FROM worktree_owners WHERE worktree_path = ?", (str(target),))
            connection.execute(REGISTRATION_SQL[LEGACY_TABLE][1], (str(target),))
        slot.rmdir()
        receipt["state"] = "cleaned"
        save(record)
