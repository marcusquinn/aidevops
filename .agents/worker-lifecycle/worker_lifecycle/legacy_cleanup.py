"""Temporary observation-era cleanup: old, ended, archive, verify, remove.

No new tables or fabricated admissions. Receipts use the existing event journal.
Current-generation cleanup is unchanged. Remove this module after the backlog.
"""

from contextlib import contextmanager
from functools import partial
import json
import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception classification; helpers execute fixed argv
import tempfile
import time
from uuid import UUID, uuid5

from .cleanup_plan import prepare_cleanup
from .directory_handle import DirectoryHandle
from .filesystem import validate_private_path as _private
from .interrupted_removal import BOUNDARY, removal_started, require_deletion_only
from .interrupted_removal import restore_git_link, validation_boundary
from .legacy_discovery import same_tree
from .legacy_inventory import inspect, inventory, unchanged
from .legacy_inventory import reconstructible, requires_reconstructible
from .legacy_options import require_manual_confirmation, require_managed_takeover
from .legacy_options import retained_outcome, unrecorded
from .legacy_probe import checkpoint, event_id, host_probe, interrupted_probe
from .legacy_probe import operation_id, prepare_reconstructible_probe, receipt
from .legacy_proc import require_idle_processes
from .legacy_probe import verify_reconstructible
from .legacy_takeover import require_managed_authority
from .preservation import _helper, _retain_base, _snapshot, verify_preservation
from .pull_requests import open_pull_requests
from .process import ObservationUnavailable
from .retirement import _git, _id, _lock


def require_confirmation(connection, operation, confirmed):
    """An interrupted capture carries manual authority before a plan exists."""
    require_manual_confirmation(
        (receipt(connection, operation, phase) for phase in ("archive", "plan")),
        confirmed,
    )


@contextmanager
def writer_released(connection):
    """Release the global writer only for non-destructive archive or network work.

    The caller retains its operation lock and must revalidate registry writers
    after reacquisition. Native source move/removal never runs in this scope.
    Body failures propagate unchanged through the outer transaction's rollback.
    Only successful work reacquires the writer; failure to reacquire still
    aborts the next phase.
    """
    connection.commit()
    yield
    connection.execute("BEGIN IMMEDIATE")


def pass_pull_requests(options):
    """Pass-memoised open-PR lookup for prechecks and journaled plans (GH#37181)."""
    return partial(options.pull_requests.get, lookup=open_pull_requests)


def released_pull_requests(connection, options, slug):
    """Open-PR lookup that never holds the registry writer across the network.

    GitHub state is not serialized by the registry. A plan built with this
    lookup is only journaled; removal requires a refreshed plan whose local,
    registry and /proc checks all run under the reacquired writer (GH#36921).
    """
    with writer_released(connection):
        return pass_pull_requests(options)(slug)


def prefetched_pull_requests(connection, options, slug):
    """Freshly fetch the journaled plan's slug without the writer; serve only that.

    `plan["repo"]` is part of the compared plan, so a refreshed plan for any other
    repository never equals the journaled plan and removal is refused. This lookup
    is never served from the pass memo, so removal rests on current GitHub state.
    """
    with writer_released(connection):
        prs = options.pull_requests.refresh(slug, open_pull_requests)
    return lambda _requested: prs


def archive_source(store, connection, operation, plan, adapter):
    """Archive the legacy source, reusing a previous archive receipt when present."""
    root = Path(plan["output_root"])
    previous = receipt(connection, operation, "archive")
    if previous is None:
        path = Path(plan["source"])
        with writer_released(connection):
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
    with writer_released(connection):
        manifest = verify_preservation(
            Path(previous["archive"]), root, previous["snapshot"],
        )
    unchanged(connection, previous, adapter)
    _retain_base(Path(plan["source"]), operation, manifest["base_sha"])
    return previous


def _restore_link(target, plan):
    """Bind tree and administration to the plan before restoring a deleted `.git`."""
    admin = Path(plan["admin"])
    if _id(target) != plan["directory"] or _id(admin) != plan["admin_identity"]:
        raise ValueError("worktree-replaced")
    restore_git_link(target, admin)


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
    with writer_released(connection):
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
    started = removal_started(connection, event_id(operation, "removing"))
    if started is not None:
        # Census before opening our own handle on the private tree.
        require_idle_processes(target)
    with DirectoryHandle(target):
        if started is not None:
            _restore_link(target, plan)
        same_tree(target, plan)
        unchanged(connection, plan, adapter)
        if started is None:
            boundary = validation_boundary()
            if _snapshot(target) != plan["snapshot"]:
                raise ValueError("relocated-source-changed")
            # Journal removal start so an interrupted delete can resume (GH#37326).
            checkpoint(store, connection, operation, "removing",
                       {"type": "legacy-worktree-removing", "archive": plan["archive"],
                        BOUNDARY: boundary})
            unchanged(connection, plan, adapter)
        else:
            require_deletion_only(target, started, _git)
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
            # Source inspection (Git, /proc census) is non-destructive filesystem
            # work: release the writer so bounded-operation admission is not
            # refused meanwhile. archive_source revalidates with unchanged()
            # under the reacquired writer before anything is journaled.
            with writer_released(connection):
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
                             pass_pull_requests(options), managed_min_age=options.min_age)
    if options.apply:
        close_quiescent_admission(store, item)
    return process_reconstructible(store, item, repositories, adapter, options)


def close_quiescent_admission(store, item):
    """Close a stranded admission once every bound run has ended (GH#37101 cause 2).

    Uses the admission pass's own primitive, which re-samples bound runs and
    closes only when every run is admitted and ended. Unenrolled, changed, empty
    or unfinished generations stay open, so the authority check that follows
    still reports `managed-admission-not-closed`. Never called in preview.
    """
    try:
        prepare_cleanup(store, Path(item["path"]))
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable):
        return


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
            # An interrupted host-probe removal is recovered or reported first.
            recover_interrupted_probe(store, item, options.apply)
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


def recover_interrupted_probe(store, item, apply):
    """Recover an interrupted probe removal; preview reports verification pending."""
    host = host_probe(store)
    with store.connection() as connection:
        if not interrupted_probe(store, connection, item):
            return
    if not apply:
        raise ValueError("reconstructible-probe-verification-pending")
    with _lock(store, host), store.connection(write=True) as connection:
        if interrupted_probe(store, connection, item):
            prepare_reconstructible_probe(store, connection, host, None, verify_reconstructible)


def current_legacy_item(connection, item):
    """Return the current inventory row for an item, or the item itself."""
    return next((row for row in inventory(connection)
                  if row["path"] == item["path"]), item)


def plan_reconstructible(store, connection, item, inspect_source, open_prs):
    """Refresh the inventory row, build its plan and require managed authority.

    The managed flag is read from the caller's item, never the refreshed row, so
    every recheck keeps the managed path guard, idle floor and authority evidence.
    """
    current = current_legacy_item(connection, item)
    plan = inspect_source(current, open_prs=open_prs)
    if item["modern"]:
        require_managed_authority(store, connection, current, plan)
    return plan


def process_reconstructible(store, item, repositories, adapter, options):
    """Journal a non-forced removal; the first successful probe unlocks batching.

    A modern generation reaches here only through `take_over_managed`.
    """
    # `None` keeps the observation-era class; managed items get the idle floor.
    inspect_source = partial(reconstructible, repositories=repositories, adapter=adapter,
                             managed_min_age=options.min_age if item["modern"] else None)
    reconstructible_plan = partial(plan_reconstructible, store, item=item,
                                   inspect_source=inspect_source)
    operation = operation_id(store, item["path"])
    outcome = {"path": item["path"], "class": "reconstructible", "status": "eligible"}
    if not options.apply:
        with store.connection() as connection:
            reconstructible_plan(connection, open_prs=pass_pull_requests(options))
        return outcome, 1, 0
    probe = host_probe(store)
    # Serialize host probes across checkpoint commits and independent invocations.
    with _lock(store, probe), _lock(store, operation), store.connection(write=True) as connection:
        # GitHub lookups release the writer (GH#36921); this plan is only journaled.
        plan = reconstructible_plan(
            connection, open_prs=partial(released_pull_requests, connection, options))
        test_removal = prepare_reconstructible_probe(store, connection, probe, plan,
                                                     verify_reconstructible)
        revision = str(uuid5(UUID(operation), json.dumps(plan, sort_keys=True)))
        checkpoint(store, connection, operation, "reconstructible-plan-" + revision, plan)
        # Fetch GitHub without the writer, then refresh every registry, Git and
        # /proc check under the reacquired writer immediately before removal.
        current = reconstructible_plan(
            connection, open_prs=prefetched_pull_requests(connection, options, plan["repo"]))
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


def run(store, config, root, **arguments):
    # Keep the existing API while separating bounded pass/report orchestration.
    """Run a legacy cleanup pass, delegating to the bounded runner."""
    from .legacy_runner import run as run_pass

    return run_pass(store, config, root, **arguments)
