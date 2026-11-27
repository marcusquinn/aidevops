"""Bounded sweep of private retirement containers left by interrupted removals."""

from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception classification; helpers execute fixed argv
import time

from . import legacy_cleanup
from .legacy_discovery import containers, managed_root
from .legacy_options import advance, queue, retained_outcome
from .process import ObservationUnavailable
from .retirement import ArchiveTarget, retire_worktree

# Bounded per-pass staging sweep: enough to drain residue without one pass
# spending its whole budget on a single large private tree.
STAGING_LIMIT = 2


def staged_plans(connection):
    """Map each journaled private container to its retirement kind and plan."""
    plans = {}
    for row in connection.execute("SELECT payload FROM events"):
        payload = json.loads(row["payload"])
        if not isinstance(payload, dict) or not isinstance(payload.get("container"), str):
            continue
        if payload.get("type") in ("retirement-planned", "legacy-worktree-removal-planned"):
            plans[payload["container"]] = (payload["type"], payload)
    return plans


def _sweep_one(store, container, entry, context):
    """Re-enter the journaled retirement path that owns one container."""
    kind, plan = entry
    repositories, adapter, options = context
    if kind == "retirement-planned":
        outcome = retire_worktree(
            store, Path(plan["source"]), plan["generation_id"],
            ArchiveTarget(plan["repo"], plan["base"], Path(plan["output_root"])),
        )
        return {"path": container, "class": "lifecycle-staging",
                "status": outcome.get("status", "retired")}
    if kind == "legacy-worktree-removal-planned":
        status = legacy_cleanup.retire(store, {"path": plan["source"]},
                                       repositories, adapter, options)
        return {"path": container, "class": "legacy-staging", "status": status}
    # Never delete a private tree no journal can describe.
    return {"path": container, "class": "staging",
            "status": "needs-operator-review",
            "reason": "staging-container-unjournaled",
            "classification": "terminal"}


STAGING_CURSOR = "legacy-staging-position"


def sweep_staging(store, repositories, adapter, options, deadline=None):
    """Complete or terminally report each private retirement container (GH#40569).

    Enumeration comes from the filesystem, so a container is found even when its
    generation left the cleanup rotation of either pass. Each one re-enters its own
    journaled retirement path, which keeps every dirty-content, identity and idle
    guard; a container that no journal owns is reported, never deleted.
    """
    if not options.apply:
        return []
    try:
        found = containers(managed_root())
    except (ValueError, OSError) as error:
        return [{"class": "staging", **retained_outcome({"path": "", "modern": False},
                                                        error)}]
    with store.connection() as connection:
        plans = staged_plans(connection)
    results = []
    # A persisted cursor rotates the selection so retained or failing containers
    # cannot starve later ones; the deadline is checked before every attempt.
    ordered = [item["path"] for item in queue(
        store, [{"path": name} for name in found], STAGING_CURSOR)]
    for container in ordered[:STAGING_LIMIT]:
        if deadline is not None and time.monotonic() >= deadline:
            break
        advance(store, container, STAGING_CURSOR)
        entry = plans.get(container, (None, None))
        try:
            results.append(_sweep_one(store, container, entry,
                                      (repositories, adapter, options)))
        except (ValueError, OSError, sqlite3.Error, ObservationUnavailable,
                subprocess.SubprocessError) as error:
            results.append({"path": container, "class": "staging",
                            **retained_outcome({"path": container, "modern": False}, error)})
    return results
