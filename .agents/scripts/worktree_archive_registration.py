#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Resolve creation registrations used by archive restoration proofs."""

import json


MANAGED_TABLE = "worktree_managed_lifetimes"
LEGACY_TABLE = "worktree_creation_backends"
NOT_ENROLLED = "restore-proof:verification-copy-not-enrolled"
# Static SQL per registration table; only values are bound as parameters.
REGISTRATION_SQL = {
    MANAGED_TABLE: ("SELECT record FROM worktree_managed_lifetimes WHERE path = ?",
                    "DELETE FROM worktree_managed_lifetimes WHERE path = ?"),
    LEGACY_TABLE: ("SELECT record FROM worktree_creation_backends WHERE path = ?",
                   "DELETE FROM worktree_creation_backends WHERE path = ?"),
}


def registration_table(registered):
    """The registry table that owns a sealed creation registration."""
    if registered.get("backend") == "legacy-guards" and "manager" not in registered:
        return LEGACY_TABLE
    return MANAGED_TABLE


def legacy_registration(connection, target):
    """Return the legacy-guards creation record for target, or None."""
    from worktree_lifetime_archive import require
    if connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                          (LEGACY_TABLE,)).fetchone() is None:
        return None
    row = connection.execute(REGISTRATION_SQL[LEGACY_TABLE][0], (str(target),)).fetchone()
    if row is None:
        return None
    registered = json.loads(row[0])
    invalid = "restore-proof:invalid-creation-backend"
    require(registered.get("schema") == 1, invalid)
    require(registration_table(registered) == LEGACY_TABLE, invalid)
    require(registered.get("identity", {}).get("path") == str(target), invalid)
    require(registered.get("generation"), invalid)
    return registered


def creation_registration(connection, target):
    """GH#35957: resolve the verification copy's creation registration.

    A managed-lifetime row wins. macOS and AIDEVOPS_WORKTREE_MANAGER=legacy-guards
    creation deliberately records only a worktree_creation_backends entry and never
    a synthetic managed receipt (worktree_lifetime_owner.register), so the proof
    binds that record's identity and generation instead.
    """
    from worktree_lifetime_archive import managed_module, require
    managed = managed_module()
    try:
        registered = managed.load(connection, str(target))
    except managed.NotEnrolled:
        registered = legacy_registration(connection, target)
        require(registered is not None, NOT_ENROLLED)
    managed.verify_identity(registered, target)
    return registered
