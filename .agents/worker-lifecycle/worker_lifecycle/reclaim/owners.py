# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Registered-owner observation for the reclaim pass; read-only, fails closed.

Ownership comes from the lifecycle registry, never from a host-wide process
scan: a worktree's generation lists the runs admitted to it, and the platform
``ProcessAdapter`` reports whether each run is still alive. Processes that never
registered are outside this contract. Every pass reports that gap as
``residual_risk`` instead of claiming no writers exist.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sqlite3

from ..cleanup_plan import _runs
from ..enrollment import GenerationEnrollment
from ..process import ObservationUnavailable, ProcessAdapter, ProcessIdentity
from ..runtime import adapter_for, require_ready
from ..storage import LifecycleRegistry

# Reported on every receipt: registry evidence cannot see unregistered processes.
RESIDUAL_RISK = "unregistered-processes-unobserved"

# Returns None when no registered owner can be alive, otherwise the refusal reason.
OwnerCheck = Callable[[Path], "str | None"]

_REGISTRY_ERRORS = (ValueError, OSError, sqlite3.Error, KeyError, TypeError)


def default_state_dir() -> Path:
    """The registry location used when the caller passes none.

    The pulse passes the directory ``worker_lifecycle_state_dir`` resolved, so
    this default serves manual runs only.
    """
    explicit = os.environ.get("AIDEVOPS_LIFECYCLE_STATE_DIR")
    if explicit:
        return Path(explicit).expanduser()
    workspace = os.environ.get("AIDEVOPS_WORKSPACE_DIR",
                               str(Path.home() / ".aidevops" / ".agent-workspace"))
    return Path(workspace).expanduser() / "worker-lifecycle"


@dataclass(frozen=True)
class RegisteredOwners:
    """One pass's registry and process adapter, opened and validated once."""

    store: LifecycleRegistry
    adapter: ProcessAdapter

    def __call__(self, path: Path) -> str | None:
        """Name why a registered owner may still be working here, or None."""
        try:
            generation = GenerationEnrollment(self.store).inspect_retirement(path)
        except ValueError as error:
            if str(error) == "not-enrolled":
                return "owner-not-enrolled"
            return "owner-registry-unreadable"
        except _REGISTRY_ERRORS:
            return "owner-registry-unreadable"
        try:
            runs = _runs(self.store, generation)
        except _REGISTRY_ERRORS:
            return "owner-registry-unreadable"
        for row in runs:
            if row["state"] == "ended":
                continue
            reason = self._observe(row)
            if reason is not None:
                return reason
        return None

    def _observe(self, row: dict) -> str | None:
        try:
            identity = ProcessIdentity.from_dict(json.loads(row["identity"]))
        except _REGISTRY_ERRORS:
            return "owner-registry-unreadable"
        try:
            status = self.adapter.observe(identity).status
        except (ObservationUnavailable, OSError, ValueError):
            return "owner-unobservable"
        if status == "alive":
            return "owner-alive"
        return None if status == "ended" else "owner-unobservable"


def open_owners(state_dir: Path) -> RegisteredOwners | None:
    """Open the registry and a ready adapter, or None when either is unusable.

    None refuses every candidate with ``owner-observation-unavailable``: a pass
    that cannot read ownership must not treat it as absent.
    """
    try:
        store = LifecycleRegistry(state_dir)
        adapter = adapter_for(store.installation_id())
        require_ready(adapter)
    except (ObservationUnavailable, *_REGISTRY_ERRORS):
        return None
    return RegisteredOwners(store, adapter)
