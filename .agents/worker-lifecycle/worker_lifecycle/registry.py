"""Lifecycle registry CLI; writes only an opt-in private store, never legacy state."""

import argparse
from collections.abc import Mapping
import json
from pathlib import Path
import sqlite3
import sys
import time
from typing import TypedDict
from uuid import uuid4

from .process import ObservationUnavailable, ProcessIdentity
from .events import ingest
from .runtime import adapter_for, require_ready
from .store import MAX_EVENT_BYTES, LifecycleRegistry, StoreCapacity, StoreConflict


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
            store.observe(str(uuid4()), row["run_id"], row["version"], observation)
            result["processed"] += 1
        except StoreConflict:
            result["deferred"] += 1
    return result


def main() -> int:
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
    args = parser.parse_args()
    result: Mapping[str, object]
    try:
        if args.operation == "init":
            require_ready(adapter_for(str(uuid4())))
            result = LifecycleRegistry.initialize(args.state_dir, max_events=args.max_events).summary()
        else:
            store = LifecycleRegistry(args.state_dir)
            if args.operation == "register":
                adapter = adapter_for(store.installation_id())
                require_ready(adapter)
                store.register(args.event_id, args.run_id, adapter.capture(args.pid))
            elif args.operation == "bind":
                store.bind(args.event_id, args.run_id, args.generation_id, args.path)
            elif args.operation == "ingest":
                ingest(store, sys.stdin.read(MAX_EVENT_BYTES + 1))
            result = reconcile(store, args.limit) if args.operation == "reconcile" else store.summary()
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable) as error:
        reason = str(error) if isinstance(error, (ObservationUnavailable, StoreCapacity)) else type(error).__name__
        print(json.dumps({"mode": "observe-only", "status": "unavailable", "reason": reason,
                          "cleanup_authorized": False}, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
