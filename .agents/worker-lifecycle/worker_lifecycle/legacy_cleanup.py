"""Temporary observation-era cleanup: old, ended, archive, verify, remove.

No new tables or fabricated admissions. Receipts use the existing event journal.
Current-generation cleanup is unchanged. Remove this module after the backlog.
"""

import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from uuid import UUID, uuid5

from .cleanup import _repositories
from .directory_handle import DirectoryHandle
from .enrollment import _git_directory
from .legacy_inventory import advance, inspect, inventory, queue, require_ended
from .preservation import _helper, _retain_base, _snapshot, verify_restoration
from .process import ObservationUnavailable
from .retirement import _git, _id, _lock
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, _private


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


def archive_source(store, connection, operation, plan, root, adapter):
    previous = receipt(connection, operation, "archive")
    if previous is None:
        path = Path(plan["source"])
        snapshot = _snapshot(path)
        archive = _helper(
            "archive", str(path), "--repo", plan["repo"], "--unattributed",
            "--reason", "unattributed-worktree", "--base-branch", plan["base"],
            "--output-root", str(root),
        )
        previous = dict(plan, type="legacy-worktree-archive", archive=archive,
                        snapshot=snapshot, output_root=str(root))
        checkpoint(store, connection, operation, "archive", previous)
    if any(previous.get(key) != value for key, value in plan.items()):
        raise ValueError("archive-source-identity-changed")
    if previous["output_root"] != str(root):
        raise ValueError("archive-root-changed")
    unchanged(connection, previous, adapter)
    manifest = verify_restoration(Path(previous["archive"]), root, previous["snapshot"])
    _retain_base(Path(plan["source"]), operation, manifest["base_sha"])
    return previous


def finish(store, connection, operation, plan, root, adapter):
    """Only the journaled private pathname is ever passed to native removal."""
    container = Path(plan["container"])
    source, target = Path(plan["source"]), container / "tree"
    if (container.parent != source.parent or container.resolve(strict=True) != container
            or not container.name.startswith(".legacy-retire-")
            or _id(container) != plan["container_identity"]):
        raise ValueError("retirement-container-changed")
    _private(container, directory=True)
    verify_restoration(Path(plan["archive"]), root, plan["snapshot"])
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


def retire(store, item, repositories, adapter, root, min_age):
    operation = operation_id(store, item["path"])
    with _lock(store, operation), store.connection(write=True) as connection:
        if receipt(connection, operation, "retired") is not None:
            return "already-retired"
        plan = receipt(connection, operation, "plan")
        if plan is None:
            current = next(row for row in inventory(connection)
                           if row["path"] == item["path"])
            identity = inspect(current, repositories, adapter, time.time(), min_age)
            with DirectoryHandle(Path(item["path"])):
                archive = archive_source(
                    store, connection, operation, identity, root, adapter,
                )
                same_tree(Path(item["path"]), identity)
                unchanged(connection, identity, adapter)
                if _snapshot(Path(item["path"])) != archive["snapshot"]:
                    raise ValueError("source-changed")
                container = Path(tempfile.mkdtemp(prefix=".legacy-retire-",
                                                  dir=Path(item["path"]).parent))
                plan = dict(archive, type="legacy-worktree-removal-planned",
                            container=str(container),
                            container_identity=_id(container))
                checkpoint(store, connection, operation, "plan", plan)
        if repositories.get(plan["common"]) != (plan["repo"], plan["base"]):
            raise ValueError("repository-scope-changed")
        if plan["output_root"] != str(root):
            raise ValueError("archive-root-changed")
        finish(store, connection, operation, plan, root, adapter)
    return "retired"


def run(store, config, root, apply=False, min_age=3600, limit=25, budget=120):
    if (not math.isfinite(min_age) or min_age < 0
            or not 1 <= limit <= 1000 or not 0 < budget <= 900):
        raise ValueError("invalid-cleanup-limits")
    repositories = _repositories(config)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    with store.connection() as connection:
        items = inventory(connection)
    if apply:
        if not root.is_absolute() or root.resolve() != root:
            raise ValueError("canonical-output-root-required")
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        _private(root, directory=True)
        items = queue(store, items)
    report = {"status": "legacy-cleanup", "apply": apply, "paths": len(items),
              "generations": sum(len(i["generations"]) for i in items),
              "retired": 0, "eligible": 0, "attempted": 0, "results": []}
    deadline = time.monotonic() + budget
    for item in items:
        if time.monotonic() >= deadline or (apply and report["attempted"] >= limit):
            break
        if apply:
            advance(store, item["path"])
        outcome = {"path": item["path"]}
        try:
            operation = operation_id(store, item["path"])
            with store.connection() as connection:
                done = receipt(connection, operation, "retired")
                pending = receipt(connection, operation, "plan")
            if done:
                outcome["status"] = "already-retired"
            else:
                if not pending:
                    inspect(item, repositories, adapter, time.time(), min_age)
                report["eligible"] += 1
                outcome["status"] = "pending-retry" if pending else "eligible"
                if apply:
                    report["attempted"] += 1
                    outcome["status"] = retire(
                        store, item, repositories, adapter, root, min_age,
                    )
                    report["retired"] += outcome["status"] == "retired"
        except (ValueError, OSError, sqlite3.Error,
                subprocess.SubprocessError) as error:
            reason = (str(error) if isinstance(error, ValueError)
                      else type(error).__name__)
            outcome.update(status="retained", reason=reason)
        report["results"].append(outcome)
    report["examined"] = len(report["results"])
    report["incomplete"] = report["examined"] < len(items)
    report["counts"] = dict(Counter(
        result.get("reason", result["status"]) for result in report["results"]
    ))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--repos-config", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--min-age-seconds", type=float, default=3600)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--budget-seconds", type=float, default=120)
    args = parser.parse_args()
    try:
        result = run(
            LifecycleRegistry(args.state_dir), args.repos_config, args.output_root,
            args.apply, args.min_age_seconds, args.limit, args.budget_seconds,
        )
    except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError,
            ObservationUnavailable) as error:
        reason = (str(error) if isinstance(error, (ValueError, ObservationUnavailable))
                  else type(error).__name__)
        print(json.dumps({"status": "unavailable", "reason": reason}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0
