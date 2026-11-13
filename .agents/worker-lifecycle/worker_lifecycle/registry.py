"""Lifecycle registry CLI; writes only an opt-in private store, never legacy state."""

import argparse
from collections.abc import Mapping
import json
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # exception type only; Git execution is audited in enrollment.py
import sys
import time
from typing import TypedDict
from uuid import uuid4

from .process import ObservationUnavailable, ProcessIdentity
from .events import ingest
from .enrollment import GenerationEnrollment
from .cleanup_plan import prepare_cleanup
from .cli_errors import error_details as _error_details
from .launch import initialize_or_open
from .runtime import adapter_for, require_ready
from .storage import DEFAULT_MAX_EVENTS, MAX_EVENT_BYTES, LifecycleRegistry, StoreConflict
from .upgrade import upgrade_registry


class ReconciliationResult(TypedDict, total=False):
    mode: str
    processed: int
    deferred: int
    cleanup_authorized: bool
    budget_exhausted: bool


def reconcile(store: LifecycleRegistry, limit: int = 100, budget: float = 5) -> ReconciliationResult:
    if not 0 < budget <= 60:
        raise ValueError("invalid-pass-budget")
    adapter = adapter_for(store.installation_id())
    # No rows are processed if the environment is globally unavailable.
    require_ready(adapter)
    deadline = time.monotonic() + budget
    result: ReconciliationResult = {"mode": "observe-only", "processed": 0, "deferred": 0, "cleanup_authorized": False}
    observations = {}
    for row in store.pending(limit):
        if time.monotonic() >= deadline:
            result["budget_exhausted"] = True
            break
        identity = ProcessIdentity.from_dict(json.loads(row["identity"]))
        if identity not in observations:
            observations[identity] = adapter.observe(identity)
        observation = observations[identity]
        try:
            if not store.refresh_unchanged(row["run_id"], row["version"], observation):
                store.observe(str(uuid4()), row["run_id"], row["version"], observation)
            result["processed"] += 1
        except StoreConflict:
            result["deferred"] += 1
    return result


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    commands = parser.add_subparsers(dest="operation", required=True)
    initialize = commands.add_parser("init", help="create a NEW private directory/store after readiness")
    initialize.add_argument("--max-events", type=int, default=DEFAULT_MAX_EVENTS)
    commands.add_parser("status", help="report aggregate registry state")
    reuse = commands.add_parser("reuse-status", help="read-only worktree reuse preflight; never admits launch")
    reuse.add_argument("--path", required=True, type=Path)
    compact = commands.add_parser("compact", help="preview archive-first retention (at most 1000 events per batch)")
    compact.add_argument("--min-age-seconds", type=int, default=None,
                         help="default: AIDEVOPS_LIFECYCLE_RETENTION_SECONDS or 86400")
    compact.add_argument("--apply", action="store_true", help="archive, verify, then delete eligible event rows")
    capacity = commands.add_parser("raise-capacity", help="preview a backed-up capacity increase; never lower the cap")
    capacity.add_argument("--max-events", type=int, required=True)
    capacity.add_argument("--apply", action="store_true")
    upgrade = commands.add_parser("upgrade", help="back up and upgrade schema-1 state")
    upgrade.add_argument("--backup-dir", type=Path,
                         help="NEW private directory; defaults to a unique directory inside state")
    commands.add_parser("ingest", help="accept one stable event envelope from stdin without recapturing its PID")
    register = commands.add_parser("register", help="capture an explicit run's process")
    register.add_argument("--event-id", required=True)
    register.add_argument("--run-id", required=True)
    register.add_argument("--pid", type=int, required=True)
    bind = commands.add_parser("bind", help="record a hypothetical binding; no ownership claim")
    bind.add_argument("--event-id", required=True)
    bind.add_argument("--run-id", required=True)
    bind.add_argument("--generation-id", required=True)
    bind.add_argument("--path", required=True)
    scan = commands.add_parser("reconcile")
    scan.add_argument("--limit", type=int, default=100)
    session = commands.add_parser(
        "admit-session", help="admit a runtime-identified owner before writes",
    )
    session.add_argument("--path", required=True, type=Path)
    session.add_argument("--pid", required=True, type=int)
    session.add_argument("--session-id", required=True)
    session.add_argument("--initialize", action="store_true")
    relinquish = commands.add_parser(
        "relinquish-session",
        help="end the calling session's own run on a tree; never closes, archives or removes",
    )
    relinquish.add_argument("--path", required=True, type=Path)
    relinquish.add_argument("--pid", required=True, type=int)
    relinquish.add_argument("--session-id", required=True)
    create = commands.add_parser("create-worktree", help="create and admit a fresh tree")
    create.add_argument("--repo", required=True, type=Path)
    create.add_argument("--path", required=True, type=Path)
    create.add_argument("--ref", required=True)
    create.add_argument("--pid", required=True, type=int)
    create.add_argument("--session-id", required=True)
    create.add_argument("--initialize", action="store_true")
    create.add_argument("git_options", nargs=argparse.REMAINDER)
    prepare = commands.add_parser(
        "prepare-cleanup", help="close quiescent admission; never delete",
    )
    prepare.add_argument("--path", required=True, type=Path)
    preserve = commands.add_parser(
        "preserve-wip", help="close admission and verify a WIP archive; never delete",
    )
    preserve.add_argument("--path", required=True, type=Path)
    preserve.add_argument("--repo", required=True)
    preserve.add_argument("--base-branch", required=True)
    preserve.add_argument("--output-root", required=True, type=Path)
    retire = commands.add_parser(
        "retire-worktree", help="archive and remove a controlled generation",
    )
    retire.add_argument("--path", required=True, type=Path)
    retire.add_argument("--generation-id", required=True)
    retire.add_argument("--repo", required=True)
    retire.add_argument("--base-branch", required=True)
    retire.add_argument("--output-root", required=True, type=Path)
    foreign = commands.add_parser(
        "retire-foreign-worktree",
        help="archive and remove a copied foreign-generation tree after rescue proof",
    )
    foreign.add_argument("--path", required=True, type=Path)
    foreign.add_argument("--repo", required=True)
    foreign.add_argument("--base-branch", required=True)
    foreign.add_argument("--output-root", required=True, type=Path)
    foreign.add_argument("--rescue-bundle", type=Path,
                         help="verified rescue bundle; omit only for a clean, pushed tree")
    foreign.add_argument("--generation-id", help="resume after relocation only")
    cleanup = commands.add_parser("cleanup", help="retire controlled registry candidates")
    cleanup.add_argument("--repos-config", required=True, type=Path)
    cleanup.add_argument("--output-root", required=True, type=Path)
    cleanup.add_argument("--limit", type=int, default=25)
    cleanup.add_argument("--budget-seconds", type=float, default=120)
    targeted = commands.add_parser(
        "cleanup-worktree", help="retire only the current controlled generation",
    )
    targeted.add_argument("--path", required=True, type=Path)
    targeted.add_argument("--repos-config", required=True, type=Path)
    targeted.add_argument("--output-root", required=True, type=Path)
    enrolled_only = commands.add_parser(
        "retire-enrolled-only",
        help="preview or confirm archive-first retirement of a never-owned enrolled tree",
    )
    enrolled_only.add_argument("--path", required=True, type=Path)
    enrolled_only.add_argument("--repos-config", required=True, type=Path)
    enrolled_only.add_argument("--output-root", required=True, type=Path)
    enrolled_only.add_argument("--confirm", action="store_true")
    vacant = commands.add_parser(
        "release-vacant-path",
        help="release the stale reservation of an absent path before re-creating it; never deletes",
    )
    vacant.add_argument("--path", required=True, type=Path)
    replaced = commands.add_parser(
        "release-replaced-path",
        help="preview or confirm releasing a reservation whose tree was replaced; never deletes",
    )
    replaced.add_argument("--path", required=True, type=Path)
    replaced.add_argument("--confirm", action="store_true")
    proof = commands.add_parser(
        "verify-retirement", help="verify dated cleanup-receipt evidence; never delete",
    )
    proof.add_argument("--path", required=True, type=Path)
    proof.add_argument("--repo", required=True)
    proof.add_argument("--branch", required=True)
    proof.add_argument("--receipt-created-at", required=True)
    for name in ("enroll", "resolve-generation"):
        enrollment = commands.add_parser(name, help="enroll or resolve a linked worktree; schema 2 required")
        enrollment.add_argument("--path", required=True, type=Path)
        if name == "enroll":
            enrollment.add_argument("--initialize", action="store_true", help="create absent state; existing schema 1 is backed up and upgraded")
            enrollment.add_argument("--allow-schema-1-observation", action="store_true", help="legacy compatibility flag; enrollment now requires automatic upgrade")
    return parser


def enrollment_result(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    enrollment = GenerationEnrollment(store)
    generation = enrollment.resolve(args.path, create=args.operation == "enroll")
    return {"generation_id": generation, "cleanup_authorized": False}


def _worktree_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    if args.operation == "create-worktree":
        from .creation import WorktreeSpec, create_worktree

        options = args.git_options
        if options[:1] == ["--"]:
            options = options[1:]
        return create_worktree(
            store, WorktreeSpec(args.repo, args.path, args.ref, tuple(options)),
            args.pid, args.session_id,
        )
    if args.operation in {"admit-session", "relinquish-session"}:
        from .session import admit_session, relinquish_session

        session_operation = admit_session if args.operation == "admit-session" else relinquish_session
        return session_operation(store, args.path, args.pid, args.session_id)
    if args.operation == "preserve-wip":
        from .preservation import preserve_wip

        return preserve_wip(store, args.path, args.repo, args.base_branch, args.output_root)
    if args.operation == "prepare-cleanup":
        return prepare_cleanup(store, args.path)
    return _retirement_operation(store, args)


def _retirement_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    from .retirement import ArchiveTarget, retire_worktree

    archive = ArchiveTarget(args.repo, args.base_branch, args.output_root)
    if args.operation == "retire-foreign-worktree":
        from .foreign_retirement import retire_foreign_worktree

        return retire_foreign_worktree(
            store, args.path, archive, args.rescue_bundle, args.generation_id,
        )
    if args.operation != "retire-worktree":
        raise ValueError("unsupported-worktree-operation")
    return retire_worktree(store, args.path, args.generation_id, archive)


def _cleanup_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    from . import cleanup, path_release

    operations = {
        "cleanup-worktree": lambda: cleanup.cleanup_worktree(
            store, args.repos_config, args.output_root, args.path,
        ),
        "retire-enrolled-only": lambda: cleanup.retire_enrolled_only(
            store, args.repos_config, args.output_root, args.path, args.confirm,
        ),
        "release-vacant-path": lambda: path_release.release_vacant_path(store, args.path),
        "release-replaced-path": lambda: path_release.release_replaced_path(
            store, args.path, args.confirm,
        ),
        "cleanup": lambda: cleanup.cleanup_pass(
            store, args.repos_config, args.output_root, args.limit, args.budget_seconds,
        ),
    }
    operation = operations.get(args.operation)
    if operation is None:
        raise ValueError("unsupported-cleanup-operation")
    return operation()


def _maintenance_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    """Dispatch read-only retirement proof and explicit registry maintenance."""
    if args.operation == "verify-retirement":
        from .retirement_proof import verify_retirement

        result = verify_retirement(
            store, args.path, args.repo, args.branch, args.receipt_created_at,
        )
    elif args.operation == "compact":
        result = store.compact(age=args.min_age_seconds, apply=args.apply)
    else:
        result = store.raise_capacity(args.max_events, apply=args.apply)
    return result


def execute_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    if args.operation in {"verify-retirement", "compact", "raise-capacity"}:
        return _maintenance_operation(store, args)
    if args.operation in {"reconcile", "enroll", "create-worktree", "admit-session"}:
        upgrade_registry(store)
    if args.operation in {"cleanup", "cleanup-worktree", "retire-enrolled-only",
                          "release-vacant-path", "release-replaced-path"}:
        return _cleanup_operation(store, args)
    if args.operation in {
        "create-worktree", "admit-session", "relinquish-session", "preserve-wip",
        "prepare-cleanup", "retire-worktree", "retire-foreign-worktree",
    }:
        return _worktree_operation(store, args)
    if args.operation == "register":
        adapter = adapter_for(store.installation_id())
        require_ready(adapter)
        store.register(args.event_id, args.run_id, adapter.capture(args.pid))
    elif args.operation == "bind":
        store.bind(args.event_id, args.run_id, args.generation_id, args.path)
    elif args.operation == "ingest":
        ingest(store, sys.stdin.read(MAX_EVENT_BYTES + 1))
    if args.operation in ("enroll", "resolve-generation"):
        return enrollment_result(store, args)
    return reconcile(store, args.limit) if args.operation == "reconcile" else store.summary()


def main() -> int:
    args = argument_parser().parse_args()
    result: Mapping[str, object]
    try:
        if args.operation == "init":
            require_ready(adapter_for(str(uuid4())))
            result = LifecycleRegistry.initialize(args.state_dir, max_events=args.max_events).summary()
        elif args.operation == "upgrade":
            result = upgrade_registry(LifecycleRegistry(args.state_dir), args.backup_dir)
        elif args.operation == "reuse-status":
            from .launch_state import reuse_status

            result = reuse_status(args.state_dir, args.path)
        else:
            if (args.operation in ("enroll", "admit-session", "create-worktree")
                    and args.initialize):
                require_ready(adapter_for(str(uuid4())))
                store = initialize_or_open(args.state_dir)
            else:
                store = LifecycleRegistry(args.state_dir)
            result = execute_operation(store, args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError, ObservationUnavailable) as error:
        print(json.dumps(_error_details(error, args.operation), sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
