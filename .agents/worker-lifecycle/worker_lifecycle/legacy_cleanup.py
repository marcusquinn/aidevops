"""Temporary observation-era cleanup: old, ended, archive, verify, remove.

No new tables or fabricated admissions. Receipts use the existing event journal.
Current-generation cleanup is unchanged. Remove this module after the backlog.
"""

from collections import Counter
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception classification; helpers execute fixed argv
import tempfile
import time
from uuid import UUID, uuid5

from .cleanup import _repositories
from .directory_handle import DirectoryHandle
from .enrollment import _git_directory
from .legacy_inventory import advance, inspect, inventory, queue, require_ended
from .preservation import _helper, _retain_base, _snapshot, verify_preservation
from .process import ObservationUnavailable
from .retirement import _git, _id, _lock
from .runtime import adapter_for, require_ready
from .storage import _private


@dataclass(frozen=True)
class CleanupOptions:
    root: Path
    apply: bool = False
    min_age: float = 3600
    limit: int = 25
    budget: float = 120

    def __post_init__(self):
        if (not math.isfinite(self.min_age) or self.min_age < 0
                or not 1 <= self.limit <= 1000 or not 0 < self.budget <= 900):
            raise ValueError("invalid-cleanup-limits")


def event_id(operation, phase):
    return str(uuid5(UUID(operation), "legacy-" + phase))


def operation_id(store, path):
    return str(uuid5(UUID(store.installation_id()), "legacy-cleanup:" + path))


def receipt(connection, operation, phase):
    row = connection.execute("SELECT payload FROM events WHERE event_id=?",
                             (event_id(operation, phase),)).fetchone()
    return json.loads(row[0]) if row else None


def checkpoint(store, connection, operation, phase, payload):
    """Persist before destructive steps, then reacquire the admission writer lock."""
    store._event(connection, event_id(operation, phase), payload)
    connection.commit()
    connection.execute("BEGIN IMMEDIATE")


def unchanged(connection, plan, adapter):
    current = next((item for item in inventory(connection)
                    if item["path"] == plan["source"]), None)
    if (current is None or current["modern"]
            or sorted(current["generations"]) != plan["generations"]
            or current["runs"] != plan["runs"]):
        raise ValueError("registered-writers-changed")
    require_ended(current, adapter)


def same_tree(path, plan):
    admin = Path(plan["admin"])
    if (_id(path) != plan["directory"] or _git_directory(path) != admin
            or _id(admin) != plan["admin_identity"]):
        raise ValueError("worktree-replaced")


def archive_source(store, connection, operation, plan, adapter):
    root = Path(plan["output_root"])
    previous = receipt(connection, operation, "archive")
    if previous is None:
        path = Path(plan["source"])
        archive = _helper(
            "archive", str(path), "--repo", plan["repo"], "--unattributed",
            "--reason", "unattributed-worktree", "--base-branch", plan["base"],
            "--output-root", str(root),
        )
        # Capture already compares before/after snapshots. Bind the receipt to
        # that captured state; finish independently rechecks the actual source.
        manifest = json.loads((Path(archive) / "manifest.json").read_bytes())
        snapshot = manifest.get("source_fingerprint")
        if not isinstance(snapshot, dict):
            raise ValueError("archive-fingerprint-missing")
        previous = dict(plan, type="legacy-worktree-archive", archive=archive,
                        snapshot=snapshot, output_root=str(root))
        checkpoint(store, connection, operation, "archive", previous)
    if any(previous.get(key) != value for key, value in plan.items()):
        raise ValueError("archive-source-identity-changed")
    if previous["output_root"] != str(root):
        raise ValueError("archive-root-changed")
    unchanged(connection, previous, adapter)
    manifest = verify_preservation(
        Path(previous["archive"]), root, previous["snapshot"],
    )
    _retain_base(Path(plan["source"]), operation, manifest["base_sha"])
    return previous


def finish(store, connection, operation, plan, adapter):
    """Only the journaled private pathname is ever passed to native removal."""
    root = Path(plan["output_root"])
    container = Path(plan["container"])
    source, target = Path(plan["source"]), container / "tree"
    if (container.parent != source.parent or container.resolve(strict=True) != container
            or not container.name.startswith(".legacy-retire-")
            or _id(container) != plan["container_identity"]):
        raise ValueError("retirement-container-changed")
    _private(container, directory=True)
    verify_preservation(Path(plan["archive"]), root, plan["snapshot"])
    unchanged(connection, plan, adapter)
    if not os.path.lexists(target):
        if not os.path.lexists(plan["admin"]):
            # A completed native removal may precede our final journal commit.
            checkpoint(store, connection, operation, "retired",
                       {"type": "legacy-worktree-retired", "archive": plan["archive"]})
            return
        same_tree(source, plan)
        if _snapshot(source) != plan["snapshot"]:
            raise ValueError("source-changed")
        _git("--git-dir", plan["common"], "worktree", "move", str(source), str(target))
    with DirectoryHandle(target):
        same_tree(target, plan)
        unchanged(connection, plan, adapter)
        if _snapshot(target) != plan["snapshot"]:
            raise ValueError("relocated-source-changed")
        _git("--git-dir", plan["common"], "worktree", "remove", "--force", str(target))
    checkpoint(store, connection, operation, "retired",
               {"type": "legacy-worktree-retired", "archive": plan["archive"]})
    container.rmdir()


def retire(store, item, repositories, adapter, options):
    operation = operation_id(store, item["path"])
    with _lock(store, operation), store.connection(write=True) as connection:
        if receipt(connection, operation, "retired") is not None:
            return "already-retired"
        plan = receipt(connection, operation, "plan")
        if plan is None:
            current = next(row for row in inventory(connection)
                           if row["path"] == item["path"])
            identity = inspect(
                current, repositories, adapter, time.time(), options.min_age,
            )
            identity["output_root"] = str(options.root)
            with DirectoryHandle(Path(item["path"])):
                archive = archive_source(
                    store, connection, operation, identity, adapter,
                )
                same_tree(Path(item["path"]), identity)
                unchanged(connection, identity, adapter)
                # finish checks content immediately before move, and again at
                # the private destination before native removal, including retry.
                container = Path(tempfile.mkdtemp(prefix=".legacy-retire-",
                                                  dir=Path(item["path"]).parent))
                plan = dict(archive, type="legacy-worktree-removal-planned",
                            container=str(container),
                            container_identity=_id(container))
                checkpoint(store, connection, operation, "plan", plan)
        if repositories.get(plan["common"]) != (plan["repo"], plan["base"]):
            raise ValueError("repository-scope-changed")
        if plan["output_root"] != str(options.root):
            raise ValueError("archive-root-changed")
        finish(store, connection, operation, plan, adapter)
    return "retired"


def process_item(store, item, repositories, adapter, options):
    outcome = {"path": item["path"]}
    eligible = attempted = 0
    try:
        operation = operation_id(store, item["path"])
        with store.connection() as connection:
            done = receipt(connection, operation, "retired")
            pending = receipt(connection, operation, "plan")
        if done:
            outcome["status"] = "already-retired"
        else:
            if not pending:
                inspect(item, repositories, adapter, time.time(), options.min_age)
            eligible = 1
            outcome["status"] = "pending-retry" if pending else "eligible"
            if options.apply:
                attempted = 1
                outcome["status"] = retire(store, item, repositories, adapter, options)
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable,
            subprocess.SubprocessError) as error:
        reason = (str(error)
                  if isinstance(error, (ValueError, ObservationUnavailable))
                  else type(error).__name__)
        outcome.update(status="retained", reason=reason)
    return outcome, eligible, attempted


def run(store, config, root, **arguments):
    options = CleanupOptions(root, **arguments)
    repositories = _repositories(config)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    with store.connection() as connection:
        items = inventory(connection)
    if options.apply:
        if not root.is_absolute() or root.resolve() != root:
            raise ValueError("canonical-output-root-required")
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        _private(root, directory=True)
        items = queue(store, items)
    report = {"status": "legacy-cleanup", "apply": options.apply, "paths": len(items),
              "generations": sum(len(i["generations"]) for i in items),
              "retired": 0, "eligible": 0, "attempted": 0, "results": []}
    deadline = time.monotonic() + options.budget
    for item in items:
        if (time.monotonic() >= deadline
                or (options.apply and report["attempted"] >= options.limit)):
            break
        if options.apply:
            advance(store, item["path"])
        outcome, eligible, attempted = process_item(
            store, item, repositories, adapter, options,
        )
        report["eligible"] += eligible
        report["attempted"] += attempted
        report["retired"] += outcome["status"] == "retired"
        report["results"].append(outcome)
    report["examined"] = len(report["results"])
    report["incomplete"] = report["examined"] < len(items)
    report["counts"] = dict(Counter(
        result.get("reason", result["status"]) for result in report["results"]
    ))
    return report
