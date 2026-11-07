"""Temporary observation-era cleanup: old, ended, archive, verify, remove.

No new tables or fabricated admissions. Receipts use the existing event journal.
Current-generation cleanup is unchanged. Remove this module after the backlog.
"""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import socket
import subprocess  # nosec B404 # exception classification; helpers execute fixed argv
import tempfile
import time
from uuid import UUID, uuid4, uuid5

from .directory_handle import DirectoryHandle
from .filesystem import validate_private_path as _private
from .legacy_discovery import same_tree
from .legacy_inventory import inspect, inventory, unchanged
from .legacy_inventory import reconstructible, requires_reconstructible
from .legacy_options import require_manual_confirmation, require_managed_takeover
from .legacy_options import retained_outcome, unrecorded
from .legacy_takeover import require_managed_authority
from .preservation import _helper, _retain_base, _snapshot, verify_preservation
from .pull_requests import open_pull_requests
from .process import ObservationUnavailable
from .retirement import _git, _id, _lock


def event_id(operation, phase):
    """Return the deterministic event ID for an operation phase."""
    return str(uuid5(UUID(operation), "legacy-" + phase))


def operation_id(store, path):
    """Return the deterministic operation ID for a legacy path."""
    return str(uuid5(UUID(store.installation_id()), "legacy-cleanup:" + path))


def receipt(connection, operation, phase):
    """Return the recorded payload for an operation phase, or None."""
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


@contextmanager
def archive_io(connection):
    """Release the global writer only for non-destructive archive operations.

    The caller retains its operation lock and must revalidate registry writers
    after reacquisition. Native source move/removal never runs in this scope.
    Body failures propagate unchanged through the outer transaction's rollback.
    Only successful archive work reacquires the writer; failure to reacquire
    still aborts the next phase.
    """
    connection.commit()
    yield
    connection.execute("BEGIN IMMEDIATE")


def archive_source(store, connection, operation, plan, adapter):
    """Archive the legacy source, reusing a previous archive receipt when present."""
    root = Path(plan["output_root"])
    previous = receipt(connection, operation, "archive")
    if previous is None:
        path = Path(plan["source"])
        with archive_io(connection):
            archive = _helper(
                "archive", str(path), "--repo", plan["repo"], "--unattributed",
                "--reason", "unattributed-worktree", "--base-branch", plan["base"],
                "--output-root", str(root),
            )
            # Capture compares before/after snapshots; bind to captured state.
            manifest = json.loads((Path(archive) / "manifest.json").read_bytes())
            snapshot = manifest.get("source_fingerprint")
            if not isinstance(snapshot, dict):
                raise ValueError("archive-fingerprint-missing")
        unchanged(connection, plan, adapter)
        previous = dict(plan, type="legacy-worktree-archive", archive=archive,
                        snapshot=snapshot, output_root=str(root))
        checkpoint(store, connection, operation, "archive", previous)
    if any(previous.get(key) != value for key, value in plan.items()):
        raise ValueError("archive-source-identity-changed")
    if previous["output_root"] != str(root):
        raise ValueError("archive-root-changed")
    unchanged(connection, previous, adapter)
    with archive_io(connection):
        manifest = verify_preservation(
            Path(previous["archive"]), root, previous["snapshot"],
        )
    unchanged(connection, previous, adapter)
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
    with archive_io(connection):
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
    """Retire one legacy item under the operation lock."""
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


def take_over_managed(store, item, repositories, adapter, options):
    """Retire a modern-generation worktree only when every safe-retirement guard holds.

    Admission cleanup owns modern generations, but a clean, pushed, idle worktree it
    never retires would otherwise stay `managed-by-current-cleanup` forever. The
    remote-recoverable guards (clean including untracked, idle /proc census, unlocked,
    HEAD on a remote ref, no open PR, non-forced removal, branch kept) decide; any
    unmet guard reports its concrete reason. Admission later reconciles the
    absent source through its existing source-absent path.
    """
    require_managed_takeover(reconstructible, item, repositories, adapter,
                             open_pull_requests, managed_min_age=options.min_age)
    return process_reconstructible(store, item, repositories, adapter, options)


def process_item(store, item, repositories, adapter, options):
    """Plan and, when applying, retire one legacy item and report the outcome."""
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
        elif not pending and not os.path.lexists(item["path"]):
            # No removal or preservation is claimed. Admission cleanup separately
            # reconciles absent generations using its existing identity guards.
            outcome["status"] = "already-absent"
        elif item["modern"]:
            return take_over_managed(store, item, repositories, adapter, options)
        elif not pending and requires_reconstructible(item, repositories, adapter, options):
            return process_reconstructible(store, item, repositories, adapter, options)
        else:
            eligible = 1
            outcome["status"] = "pending-retry" if pending else "eligible"
            if options.apply:
                attempted = 1
                outcome["status"] = retire(store, item, repositories, adapter, options)
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable,
            subprocess.SubprocessError) as error:
        outcome.update(retained_outcome(item, error))
    return outcome, eligible, attempted


def prepare_reconstructible_probe(store, connection, host, plan):
    """Recover removed probes; cancel unremoved attempts only by native identity."""
    if receipt(connection, host, "verified") is not None:
        return False
    row = connection.execute(
        "SELECT payload FROM events WHERE json_extract(payload,'$.type')=? "
        "AND json_extract(payload,'$.host')=? ORDER BY sequence DESC LIMIT 1",
        ("reconstructible-host-probe-plan", host),
    ).fetchone()
    if row:
        previous = json.loads(row[0])
        original = previous["plan"]
        if not os.path.lexists(original["source"]):
            try:
                verify_reconstructible(original, probe=True)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                raise ValueError("reconstructible-probe-verification-pending") from error
            checkpoint(store, connection, host, "verified",
                       dict(original, type="reconstructible-host-probe-verified"))
            checkpoint(store, connection, operation_id(store, original["source"]),
                       "retired", dict(original, type="reconstructible-worktree-retired",
                                       branch_preserved=True))
            return False
        # An intact original worktree/admin proves removal never completed.
        # A replacement or unresolved missing source must not unlock batching.
        same_tree(Path(original["source"]), original)
        checkpoint(store, connection, previous["attempt"], "cancelled",
                   {"type": "reconstructible-host-probe-cancelled", "host": host})
    attempt = str(uuid4())
    checkpoint(store, connection, attempt, "plan",
               {"type": "reconstructible-host-probe-plan", "host": host,
                "attempt": attempt, "plan": plan})
    return True


def current_legacy_item(connection, item):
    """Return the current inventory row for an item, or the item itself."""
    return next((row for row in inventory(connection)
                  if row["path"] == item["path"]), item)


def legacy_plan(store, connection, item, repositories, adapter):
    """Build a reconstructible plan for a legacy item."""
    return reconstructible(item, repositories, adapter, open_pull_requests)


def managed_planner(min_age):
    """Return a plan builder for managed items with the idle floor and authority."""
    def managed_plan(store, connection, item, repositories, adapter):
        plan = reconstructible(item, repositories, adapter, open_pull_requests,
                               managed_min_age=min_age)
        require_managed_authority(store, connection, item, plan)
        return plan
    return managed_plan


def process_reconstructible(store, item, repositories, adapter, options):
    """Journal a non-forced removal; the first successful probe unlocks batching.

    A modern generation reaches here only through `take_over_managed`. Its flag is
    read once from the caller's item, so every recheck keeps the managed path guard
    and authority evidence even if the refreshed inventory row differs.
    """
    reconstructible_plan = (managed_planner(options.min_age)
                            if item["modern"] else legacy_plan)
    operation = operation_id(store, item["path"])
    outcome = {"path": item["path"], "class": "reconstructible", "status": "eligible"}
    if not options.apply:
        with store.connection() as connection:
            reconstructible_plan(store, connection, current_legacy_item(connection, item),
                                 repositories, adapter)
        return outcome, 1, 0
    probe = str(uuid5(UUID(store.installation_id()),
                      "reconstructible-host-probe:" + socket.gethostname()))
    # Serialize host probes across checkpoint commits and independent invocations.
    with _lock(store, probe), _lock(store, operation), store.connection(write=True) as connection:
        item = current_legacy_item(connection, item)
        plan = reconstructible_plan(store, connection, item, repositories, adapter)
        test_removal = prepare_reconstructible_probe(store, connection, probe, plan)
        revision = str(uuid5(UUID(operation), json.dumps(plan, sort_keys=True)))
        checkpoint(store, connection, operation, "reconstructible-plan-" + revision, plan)
        # Refresh GitHub and /proc immediately before non-forced native removal.
        current = reconstructible_plan(store, connection, current_legacy_item(connection, item),
                                       repositories, adapter)
        if current != plan:
            raise ValueError("reconstructible-source-changed")
        _git("--git-dir", plan["common"], "worktree", "remove", plan["source"])
        verify_reconstructible(plan, probe=test_removal)
        checkpoint(store, connection, operation, "retired",
                   dict(plan, type="reconstructible-worktree-retired", branch_preserved=True))
        if test_removal:
            checkpoint(store, connection, probe, "verified",
                       dict(plan, type="reconstructible-host-probe-verified"))
        outcome["status"] = "retired"
    return outcome, 1, 1


def verify_reconstructible(plan, *, probe):
    """Verify the removed source can be reconstructed from retained Git objects."""
    if os.path.lexists(plan["source"]):
        raise ValueError("reconstructible-source-still-present")
    common, head, branch = plan["common"], plan["head"], plan["branch"]
    _git("--git-dir", common, "cat-file", "-e", head + "^{commit}")
    if branch != "HEAD" and _git("--git-dir", common, "rev-parse", branch) != head:
        raise ValueError("reconstructible-branch-changed")
    if probe:
        # A fresh disposable checkout proves restoration without touching the branch.
        parent = Path(tempfile.mkdtemp(prefix=".reconstructible-probe-",
                                      dir=Path(plan["source"]).parent))
        target = str(parent / "tree")
        _git("--git-dir", common, "worktree", "add", "--detach", target, head)
        if _git("-C", target, "rev-parse", "HEAD") != head:
            raise ValueError("reconstructible-restore-mismatch")
        _git("--git-dir", common, "worktree", "remove", target)
        parent.rmdir()


def run(store, config, root, **arguments):
    # Keep the existing API while separating bounded pass/report orchestration.
    """Run a legacy cleanup pass, delegating to the bounded runner."""
    from .legacy_runner import run as run_pass

    return run_pass(store, config, root, **arguments)
