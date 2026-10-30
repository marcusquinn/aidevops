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
from .launch import initialize_or_open
from .runtime import adapter_for, require_ready
from .storage import MAX_EVENT_BYTES, LifecycleRegistry, StoreCapacity, StoreConflict


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
    initialize.add_argument("--max-events", type=int, default=10000)
    commands.add_parser("status", help="report aggregate registry state")
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
    for name in ("enroll", "resolve-generation"):
        enrollment = commands.add_parser(name, help="enroll or resolve a linked worktree; schema 2 required")
        enrollment.add_argument("--path", required=True, type=Path)
        if name == "enroll":
            enrollment.add_argument("--initialize", action="store_true", help="create absent state; never migrate existing state")
            enrollment.add_argument("--allow-schema-1-observation", action="store_true", help="report an unenrolled schema-1 creation as a coverage gap, never as admission")
    return parser


def enrollment_result(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
    enrollment = GenerationEnrollment(store)
    if getattr(args, "allow_schema_1_observation", False) and enrollment.has_schema_one_gap(args.path):
        print("[worker-lifecycle] coverage-gap: schema-upgrade-required; no generation admitted", file=sys.stderr)
        return {"status": "coverage-gap", "reason": "schema-upgrade-required", "cleanup_authorized": False}
    generation = enrollment.resolve(args.path, create=args.operation == "enroll")
    return {"generation_id": generation, "cleanup_authorized": False}


def execute_operation(store: LifecycleRegistry, args: argparse.Namespace) -> Mapping[str, object]:
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
        else:
            if args.operation == "enroll" and args.initialize:
                require_ready(adapter_for(str(uuid4())))
                store = initialize_or_open(args.state_dir)
            else:
                store = LifecycleRegistry(args.state_dir)
            result = execute_operation(store, args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError, ObservationUnavailable) as error:
        reason = str(error) if isinstance(error, (ObservationUnavailable, StoreCapacity)) else type(error).__name__
        detail = {"mode": "observe-only", "status": "unavailable", "reason": reason,
                  "cleanup_authorized": False}
        # GH#36142: name the enrollment refusal; OSError text may carry paths.
        if args.operation == "enroll" and isinstance(error, ValueError):
            detail["detail"] = str(error)[:200]
        print(json.dumps(detail, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
