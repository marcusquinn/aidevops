#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private, best-effort recovery timings; never recovery or deletion evidence."""

import argparse
from collections import defaultdict
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime, timezone
from functools import wraps
import json
import math
import os
from pathlib import Path
import re
import stat
import statistics
import sys
import time
import uuid


CURRENT = ContextVar("recovery_timing", default=None)


def context(**fields):
    trace = CURRENT.get()
    if trace is not None:
        trace["fields"].update(fields)


def child_environment(environment):
    """Keep a child stage under its actual parent, not a second additive total."""
    trace = CURRENT.get()
    if trace is not None and trace["stack"]:
        environment.update(AIDEVOPS_RECOVERY_TIMING_ATTEMPT=trace["id"],
                           AIDEVOPS_RECOVERY_TIMING_PARENT=trace["stack"][-1],
                           AIDEVOPS_RECOVERY_TIMING_OPERATION=trace["operation"],
                           AIDEVOPS_RECOVERY_TIMING_REPO=str(trace["fields"].get("repo", "unknown")))


def emit(trace, **event):
    """Append one bounded record without following a file symlink or blocking on a FIFO."""
    if trace["unavailable"]:
        return
    descriptor = None
    try:
        path = Path(os.environ.get("AIDEVOPS_RECOVERY_TIMING_LOG") or
                    Path.home() / ".aidevops/logs/worktree-recovery-timings.jsonl")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.parent.resolve() != path.parent.absolute():
            raise OSError("unsafe-log-parent")
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT |
                             os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        observed = os.fstat(descriptor)
        if (not stat.S_ISREG(observed.st_mode) or observed.st_uid != os.getuid()
                or observed.st_nlink != 1 or stat.S_IMODE(observed.st_mode) != 0o600):
            raise OSError("unsafe-log-file")
        row = dict(schema="aidevops.recovery-timing/v1", attempt_id=trace["id"],
                   operation=trace["operation"], pid=os.getpid(),
                   timestamp=datetime.now(timezone.utc).isoformat(),
                   **trace["fields"], **event)
        data = (json.dumps(row, sort_keys=True) + "\n").encode()
        if len(data) > 16384 or os.write(descriptor, data) != len(data):
            raise OSError("incomplete-log-write")
    except (OSError, ValueError, RuntimeError):
        trace["unavailable"] = True
        print("recovery-timing: log unavailable; archive safety checks remain unchanged", file=sys.stderr)
    finally:
        if descriptor is not None:
            os.close(descriptor)


@contextmanager
def phase(name):
    trace = CURRENT.get()
    inherited = None
    if trace is None:
        attempt = os.environ.get("AIDEVOPS_RECOVERY_TIMING_ATTEMPT", "")
        parent = os.environ.get("AIDEVOPS_RECOVERY_TIMING_PARENT", "")
        operation_name = os.environ.get("AIDEVOPS_RECOVERY_TIMING_OPERATION", "")
        if not (re.fullmatch(r"[0-9a-f]{32}", attempt) and re.fullmatch(r"[0-9a-f]{32}", parent)
                and re.fullmatch(r"[a-z-]{1,64}", operation_name)):
            yield
            return
        trace = {"id": attempt, "operation": operation_name,
                 "fields": {"repo": os.environ.get("AIDEVOPS_RECOVERY_TIMING_REPO", "unknown")},
                 "stack": [parent], "unavailable": False}
        inherited = CURRENT.set(trace)
    stage_id = uuid.uuid4().hex
    parent = trace["stack"][-1] if trace["stack"] else None
    fields = {"stage": name, "stage_id": stage_id, "parent_stage_id": parent}
    started = time.monotonic_ns()
    emit(trace, **fields, event="start")
    trace["stack"].append(stage_id)
    outcome = {"status": "success"}
    try:
        yield
    except BaseException as error:
        outcome = {"status": "failed", "error_type": type(error).__name__}
        if isinstance(error, ValueError) and re.fullmatch(r"[A-Za-z0-9:_ .;-]{1,160}", str(error)):
            outcome["reason"] = str(error)
        if isinstance(getattr(error, "returncode", None), int):
            outcome["exit_code"] = error.returncode
        raise
    finally:
        trace["stack"].pop()
        emit(trace, **fields, **outcome, event="finish",
              duration_ms=round((time.monotonic_ns() - started) / 1_000_000, 3))
        if inherited is not None:
            CURRENT.reset(inherited)


def timed(name):
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            with phase(name):
                return function(*args, **kwargs)
        return wrapped
    return decorate


def operation(name):
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            trace = {"id": uuid.uuid4().hex, "operation": name, "fields": {},
                     "stack": [], "unavailable": False}
            token = CURRENT.set(trace)
            try:
                with phase("total"):
                    return function(*args, **kwargs)
            finally:
                CURRENT.reset(token)
        return wrapped
    return decorate


def parse_record(line):
    row = json.loads(line)
    if not isinstance(row, dict) or row.get("schema") != "aidevops.recovery-timing/v1":
        raise ValueError("unknown record")
    if not all(isinstance(row.get(key), str) for key in
               ("attempt_id", "stage_id", "stage", "operation", "event")):
        raise ValueError("invalid record identity")
    identity = (row["attempt_id"], row["stage_id"])
    if row["event"] == "start":
        return identity, None
    duration = row.get("duration_ms")
    if row["event"] != "finish" or row.get("status") not in ("success", "failed"):
        raise ValueError("invalid completion")
    if type(duration) not in (int, float) or not math.isfinite(duration) or duration < 0:
        raise ValueError("invalid completion")
    repo = row.get("repo", "unknown")
    if not isinstance(repo, str):
        raise ValueError("invalid repository")
    return identity, ((repo, row["operation"], row["stage"], row["status"]), duration)


def summary(path):
    """Report measured completions only; incomplete and malformed records stay explicit."""
    groups = defaultdict(list)
    starts, finishes = set(), set()
    invalid = 0
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        observed = os.fstat(source.fileno())
        if not stat.S_ISREG(observed.st_mode) or observed.st_uid != os.getuid():
            raise ValueError("unsafe timing log")
        if observed.st_size > 64 * 1024 * 1024:
            raise ValueError("timing log exceeds 64 MiB report limit; select an archived log")
        for _ in range(100000):
            line = source.readline(16385)
            if not line:
                break
            if len(line) > 16384:
                raise ValueError("oversized timing record")
            try:
                identity, completion = parse_record(line)
                if completion is None:
                    starts.add(identity)
                    continue
                if identity in finishes:
                    raise ValueError("duplicate completion")
                finishes.add(identity)
                key, duration = completion
                groups[key].append(duration)
            except (ValueError, TypeError):
                invalid += 1
        else:
            raise ValueError("timing log exceeds 100000-record report limit")
    rows = [{"repo": key[0], "operation": key[1], "stage": key[2], "status": key[3],
             "count": len(values), "min_ms": min(values),
             "median_ms": statistics.median(values), "max_ms": max(values)}
            for key, values in sorted(groups.items())]
    return {"schema": "aidevops.recovery-timing-summary/v1", "read_only": True,
            "duration_scope": "inclusive Python transaction stages; excludes outer shell preflight and removal",
            "invalid_records": invalid, "unfinished_stages": len(starts - finishes),
            "finishes_without_start": len(finishes - starts), "groups": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("report",))
    parser.add_argument("--log", type=Path, default=Path(os.environ.get("AIDEVOPS_RECOVERY_TIMING_LOG") or
                        Path.home() / ".aidevops/logs/worktree-recovery-timings.jsonl"))
    args = parser.parse_args()
    try:
        print(json.dumps(summary(args.log), sort_keys=True))
    except (OSError, ValueError) as error:
        print(json.dumps({"read_only": True, "error_type": type(error).__name__, "report_available": False}))
        sys.exit(1)
