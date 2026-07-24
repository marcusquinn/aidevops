#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Process-table and generation identity resolution for termination guards."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from process_termination_common import (
    ProcessRecord,
    RuntimeIdentityError,
    _normalise_identity,
)

PROCESS_LINE = re.compile(
    r"^\s*(?P<pid>[0-9]+)\s+(?P<ppid>[0-9]+)\s+(?P<pgid>-?[0-9]+)\s+"
    r"(?P<start>[A-Za-z]{3}\s+[A-Za-z]{3}\s+[0-9]+\s+"
    r"[0-9]{2}:[0-9]{2}:[0-9]{2}\s+[0-9]{4})\s+"
    r"(?P<comm>.+?)\s*$"
)


def _load_fixture(path: Path) -> list[ProcessRecord]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeIdentityError(
            "mocked process identity evidence is unavailable"
        ) from exc
    rows = payload.get("processes") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise RuntimeIdentityError("mocked process identity evidence is malformed")
    try:
        records = [
            ProcessRecord(
                pid=int(row["pid"]),
                ppid=int(row["ppid"]),
                pgid=int(row["pgid"]),
                start=_normalise_identity(str(row["start"])),
                comm=str(row["comm"]),
                args=str(row.get("args", "")),
            )
            for row in rows
            if isinstance(row, dict)
        ]
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeIdentityError(
            "mocked process identity evidence is malformed"
        ) from exc
    if len(records) != len(rows):
        raise RuntimeIdentityError("mocked process identity evidence is malformed")
    return records


def _run_process_view(columns: str) -> str:
    ps_binary = "/bin/ps" if Path("/bin/ps").is_file() else "ps"
    try:
        completed = subprocess.run(  # nosec B603 -- fixed system process viewer.
            [ps_binary, "-ww", "-axo", columns],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeIdentityError(
            "current runtime process identity is unavailable"
        ) from exc
    if completed.returncode != 0:
        raise RuntimeIdentityError("current runtime process identity is unavailable")
    return completed.stdout


def _load_live_processes() -> list[ProcessRecord]:
    process_output = _run_process_view("pid=,ppid=,pgid=,lstart=,comm=")
    arguments_output = _run_process_view("pid=,args=")
    arguments_by_pid: dict[int, str] = {}
    for line in arguments_output.splitlines():
        fields = line.strip().split(None, 1)
        if fields and fields[0].isdigit():
            arguments_by_pid[int(fields[0], 10)] = fields[1] if len(fields) > 1 else ""
    records = []
    for line in process_output.splitlines():
        match = PROCESS_LINE.match(line)
        if not match:
            continue
        pid = int(match["pid"])
        records.append(
            ProcessRecord(
                pid=pid,
                ppid=int(match["ppid"]),
                pgid=int(match["pgid"]),
                start=_normalise_identity(match["start"]),
                comm=match["comm"].strip(),
                args=arguments_by_pid.get(pid, ""),
            )
        )
    if not records:
        raise RuntimeIdentityError("current runtime process identity is unavailable")
    return records


def _runtime_lineage(
    records: list[ProcessRecord], runtime_pid: int, expected_identity: str
) -> list[ProcessRecord]:
    if runtime_pid <= 0 or not expected_identity:
        raise RuntimeIdentityError("current runtime process identity is missing")
    by_pid = {record.pid: record for record in records}
    runtime = by_pid.get(runtime_pid)
    if runtime is None:
        raise RuntimeIdentityError("current runtime process identity is no longer live")
    if runtime.start != _normalise_identity(expected_identity):
        raise RuntimeIdentityError(
            "current runtime PID belongs to a different process generation"
        )
    lineage = []
    seen = set()
    current = runtime
    while True:
        if current.pid in seen:
            raise RuntimeIdentityError("current runtime ancestry is contradictory")
        seen.add(current.pid)
        lineage.append(current)
        if current.ppid == 0:
            return lineage
        parent = by_pid.get(current.ppid)
        if parent is None:
            raise RuntimeIdentityError("current runtime ancestry is incomplete")
        current = parent
