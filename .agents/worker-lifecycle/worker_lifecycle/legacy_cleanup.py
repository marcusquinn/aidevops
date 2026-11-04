"""Temporary observation-era cleanup: old, ended, archive, verify, remove.

No new tables or fabricated admissions. Receipts use the existing event journal.
Current-generation cleanup is unchanged. Remove this module after the backlog.
"""

from collections import Counter
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception classification; helpers execute fixed argv
import tempfile
import time
from uuid import UUID, uuid5

from .archive_path import create_archive_root, validate_archive_path
from .cleanup import _failure_details, _repositories
from .directory_handle import DirectoryHandle
from .enrollment import _git_directory
from .filesystem import validate_private_path as _private
from .legacy_discovery import discover
from .legacy_inventory import advance, inspect, inventory, queue, require_ended
from .legacy_inventory import reconstructible
from .legacy_options import CleanupOptions, require_manual_confirmation, unrecorded
from .preservation import _helper, _retain_base, _snapshot, verify_preservation
from .process import ObservationUnavailable
from .retirement import _git, _id, _lock
from .runtime import adapter_for, require_ready


def event_id(operation, phase):
    return str(uuid5(UUID(operation), "legacy-" + phase))


def operation_id(store, path):
    return str(uuid5(UUID(store.installation_id()), "legacy-cleanup:" + path))


def receipt(connection, operation, phase):
    row = connection.execute("SELECT payload FROM events WHERE event_id=?",
                             (event_id(operation, phase),)).fetchone()
    return json.loads(row[0]) if row else None


def require_confirmation(connection, operation, confirmed):
    """An interrupted capture carries manual authority before a plan exists."""
    require_manual_confirmation(
        (receipt(connection, operation, phase) for phase in ("archive", "plan")),
        confirmed,
    )


def checkpoint(store, connection, operation, phase, payload):
    """Persist before destructive steps, then reacquire the admission writer lock."""
    store._event(connection, event_id(operation, phase), payload)
    connection.commit()
    connection.execute("BEGIN IMMEDIATE")


def unchanged(connection, plan, adapter):
    current = next((item for item in inventory(connection)
                     if item["path"] == plan["source"]), None)
    confirmed = plan.get("operator_confirmed") is True
    if current is None and confirmed:
        current = unrecorded(plan["source"])
    if (current is None or current["modern"]
            or sorted(current["generations"]) != plan["generations"]
            or current["runs"] != plan["runs"]):
        raise ValueError("registered-writers-changed")
    require_ended(current, adapter, operator_confirmed=confirmed)


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
    confirmed = item["path"] in options.confirmed_paths
    with _lock(store, operation), store.connection(write=True) as connection:
        if receipt(connection, operation, "retired") is not None:
            return "already-retired"
        require_confirmation(connection, operation, confirmed)
        plan = receipt(connection, operation, "plan")
        if plan is None:
            current = next((row for row in inventory(connection)
                            if row["path"] == item["path"]), unrecorded(item["path"]))
            identity = inspect(
                current, repositories, adapter, time.time(), options,
            )
            identity["output_root"] = str(options.root)
            if confirmed:
                identity["operator_confirmed"] = True
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
        confirmed = item["path"] in options.confirmed_paths
        with store.connection() as connection:
            done = receipt(connection, operation, "retired")
            pending = receipt(connection, operation, "plan")
            if not done:
                require_confirmation(connection, operation, confirmed)
        if done:
            outcome["status"] = "already-retired"
        else:
            if not pending:
                try:
                    inspect(item, repositories, adapter, time.time(), options)
                except ValueError as error:
                    if str(error) != "no-recorded-processes":
                        raise
                    return process_reconstructible(store, item, repositories, adapter, options)
            eligible = 1
            outcome["status"] = "pending-retry" if pending else "eligible"
            if options.apply:
                attempted = 1
                outcome["status"] = retire(store, item, repositories, adapter, options)
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable,
            subprocess.SubprocessError) as error:
        outcome.update(status="retained", **_failure_details(error))
        if isinstance(error, ObservationUnavailable):
            outcome["reason"] = str(error)
    return outcome, eligible, attempted


def open_pull_requests(slug):
    """All pages or no authority; never infer absence from a failed API call."""
    result = subprocess.run(  # nosec B603 B607 # fixed gh argv, validated slug
        ["gh", "api", "--paginate", "--slurp",
         f"repos/{slug}/pulls?state=open&per_page=100"],
        check=True, capture_output=True, text=True, timeout=60,
    )
    pages = json.loads(result.stdout)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("invalid-open-pr-response")
    return [pr for page in pages for pr in page]


def process_reconstructible(store, item, repositories, adapter, options):
    """Journal a non-forced removal; the first successful probe unlocks batching."""
    operation = operation_id(store, item["path"])
    outcome = {"path": item["path"], "class": "reconstructible", "status": "eligible"}
    with _lock(store, operation), store.connection(write=True) as connection:
        plan = reconstructible(item, repositories, adapter, open_pull_requests)
        if not options.apply:
            return outcome, 1, 0
        probe = str(uuid5(UUID(store.installation_id()), "reconstructible-host-probe"))
        verified = receipt(connection, probe, "verified")
        # A previous incomplete test blocks batch mode, including after restart.
        if verified is None and receipt(connection, probe, "plan") is not None:
            raise ValueError("reconstructible-probe-verification-pending")
        if verified is None:
            checkpoint(store, connection, probe, "plan", plan)
        checkpoint(store, connection, operation, "reconstructible-plan", plan)
        # Refresh GitHub and /proc immediately before non-forced native removal.
        current = reconstructible(item, repositories, adapter, open_pull_requests)
        if current != plan:
            raise ValueError("reconstructible-source-changed")
        _git("--git-dir", plan["common"], "worktree", "remove", plan["source"])
        verify_reconstructible(plan, probe=verified is None)
        checkpoint(store, connection, operation, "retired",
                   dict(plan, type="reconstructible-worktree-retired", branch_preserved=True))
        if verified is None:
            checkpoint(store, connection, probe, "verified",
                       dict(plan, type="reconstructible-host-probe-verified"))
        outcome["status"] = "retired"
    return outcome, 1, 1


def verify_reconstructible(plan, *, probe):
    if os.path.lexists(plan["source"]):
        raise ValueError("reconstructible-source-still-present")
    common, head, branch = plan["common"], plan["head"], plan["branch"]
    _git("--git-dir", common, "cat-file", "-e", head + "^{commit}")
    if branch != "HEAD" and _git("--git-dir", common, "rev-parse", branch) != head:
        raise ValueError("reconstructible-branch-changed")
    if probe:
        # A fresh disposable checkout proves restoration without touching the branch.
        with tempfile.TemporaryDirectory(prefix=".reconstructible-probe-",
                                         dir=Path(plan["source"]).parent) as parent:
            target = str(Path(parent) / "tree")
            _git("--git-dir", common, "worktree", "add", "--detach", target, head)
            if _git("-C", target, "rev-parse", "HEAD") != head:
                raise ValueError("reconstructible-restore-mismatch")
            _git("--git-dir", common, "worktree", "remove", target)


def run(store, config, root, **arguments):
    options = CleanupOptions(root, **arguments)
    repositories = _repositories(config)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    with store.connection() as connection:
        items = inventory(connection)
    items, discovery_errors = discover(items, repositories)
    items = options.select(items)
    if options.apply:
        if not root.is_absolute() or root.resolve() != root:
            raise ValueError("canonical-output-root-required")
        create_archive_root(root)
        validate_archive_path(root)
        items = queue(store, items)
    report: dict = {
        "status": "legacy-cleanup", "apply": options.apply, "paths": len(items),
        "generations": sum(len(i["generations"]) for i in items),
        "retired": 0, "eligible": 0, "attempted": 0, "results": [],
        "discovery_errors": discovery_errors,
        "operator_confirmed_paths": list(options.confirmed_paths),
    }
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
    report["incomplete"] = bool(discovery_errors) or report["examined"] < len(items)
    report["archive_failed"] = sum(
        bool(result.get("archive_failure", False)) for result in report["results"]
    )
    report["counts"] = dict(Counter(
        result.get("reason", result["status"]) for result in report["results"]
    ))
    return report
