#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Append-only, token-free checkpoint evidence sharing the objective log lock."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import time

PREFIX = "terminal_lease_"
KEYS = ("repo", "issue_number", "attempt_id", "session", "claim_id", "device")


def evidence_path():
    return Path(os.environ.get("AIDEVOPS_OBJECTIVE_EVIDENCE_FILE",
                               str(Path.home() / ".aidevops/state/objective-evidence.jsonl")))


def device_id():
    path = Path(os.environ.get("AIDEVOPS_DEVICE_ID_FILE",
                               str(Path.home() / ".aidevops/state/device-id")))
    value = path.read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", value):
        raise ValueError("invalid-device")
    return value


def rows(path):
    if not path.exists():
        return []
    result = []
    with path.open() as stream:
        for line in stream:
            try:
                row = json.loads(line)
                if isinstance(row, dict) and str(row.get("record_type", "")).startswith(PREFIX):
                    result.append(row)
            except ValueError:
                continue
    return result


def key(row):
    return tuple(row.get(name) for name in KEYS)


@contextmanager
def locked(path):
    """Share the objective writer's mkdir/owner.pid append lock, never unlocked."""
    lock = Path(str(path) + ".lockdir")
    path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(40):
        try:
            lock.mkdir()
            break
        except FileExistsError:
            time.sleep(0.05)
    else:
        raise TimeoutError("evidence-lock-busy")
    try:
        (lock / "owner.pid").write_text(str(os.getpid()) + "\n")
        yield
    finally:
        (lock / "owner.pid").unlink(missing_ok=True)
        lock.rmdir()


def append(path, row):
    with locked(path):
        history = [old for old in rows(path) if key(old) == key(row)]
        kind = row["record_type"]
        if any(old["record_type"] == kind for old in history):
            return
        if kind == PREFIX + "resolved" and not history:
            return
        # Preserve an interrupted last write as evidence, but do not concatenate
        # the next valid record onto its partial JSON and silently lose both.
        separator = ""
        if path.exists() and path.stat().st_size:
            with path.open("rb") as existing:
                existing.seek(-1, os.SEEK_END)
                if existing.read(1) != b"\n":
                    separator = "\n"
        with path.open("a") as stream:
            stream.write(separator)
            stream.write(json.dumps(row, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
