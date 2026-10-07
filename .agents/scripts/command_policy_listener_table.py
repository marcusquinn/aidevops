#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Complete TCP LISTEN enumeration for worker-owned listener proofs (GH#33969).

lsof attributes listeners to PIDs but only for processes the caller may
inspect; netstat (macOS/BSD) and ss (Linux) list every socket without
attribution. A port is only provable when every LISTEN address the system
reports was also attributed by lsof.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess  # nosec B404 -- fixed system binaries and argv, no shell.
from pathlib import Path


class OwnershipError(ValueError):
    """Raised when listener ownership cannot be proven."""


def _normalise_host(value: str) -> str:
    host = value.strip().strip("[]").split("%", 1)[0].lower()
    return "*" if host in {"", "*", "0.0.0.0", "::"} else host


def _split_address(value: str, separator: str) -> tuple[str, int] | None:
    host, sep, port = value.rpartition(separator)
    if not sep or not port.isdigit():
        return None
    return _normalise_host(host), int(port)


def _listener_fixture(path: str, port: int) -> tuple[set[int], set[str], set[str]]:
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        rows = [row for row in payload["listeners"] if int(row["port"]) == port]
        hosts = {_normalise_host(str(row.get("address", "127.0.0.1"))) for row in rows}
        system = payload.get("system")
        system_hosts = hosts if system is None else {
            _normalise_host(str(row["address"])) for row in system if int(row["port"]) == port
        }
        return {int(row["pid"]) for row in rows}, hosts, system_hosts
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        raise OwnershipError("listener fixture is unavailable or malformed") from exc


def _run_fixed(argv: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(  # nosec B603 -- fixed system binary and argv.
            argv, capture_output=True, text=True, timeout=5, check=False,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise OwnershipError("listener lookup failed") from exc


def _system_binary(path: str, name: str) -> str:
    binary = path if Path(path).is_file() else shutil.which(name)
    if not binary:
        raise OwnershipError(f"{name} is required to prove listener ownership")
    return binary


def _lsof_listeners(port: int) -> tuple[set[int], set[str]]:
    completed = _run_fixed(
        [_system_binary("/usr/sbin/lsof", "lsof"), "-nP", "-a", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpn"]
    )
    if completed.returncode not in (0, 1) or (completed.returncode == 1 and completed.stdout.strip()):
        raise OwnershipError("listener lookup failed")
    pids: set[int] = set()
    hosts: set[str] = set()
    for line in completed.stdout.splitlines():
        if line[:1] == "p" and line[1:].isdigit():
            pids.add(int(line[1:]))
        elif line[:1] == "n":
            address = _split_address(line[1:], ":")
            if address is None or address[1] != port:
                raise OwnershipError("listener lookup returned an unexpected address")
            hosts.add(address[0])
    return pids, hosts


def _system_listen_hosts(port: int) -> set[str]:
    """Return every LISTEN address on port, regardless of socket owner."""
    if Path("/usr/sbin/netstat").is_file() and not Path("/proc/net/tcp").exists():
        completed = _run_fixed(["/usr/sbin/netstat", "-an", "-p", "tcp"])
        rows = [line.split() for line in completed.stdout.splitlines()]
        locals_ = [row[3] for row in rows if len(row) >= 6 and row[-1] == "LISTEN"]
        separator = "."
    else:
        completed = _run_fixed([_system_binary("/usr/bin/ss", "ss"), "-Hltn"])
        rows = [line.split() for line in completed.stdout.splitlines()]
        locals_ = [row[3] for row in rows if len(row) >= 5]
        separator = ":"
    if completed.returncode != 0:
        raise OwnershipError("socket table lookup failed")
    hosts = set()
    for local in locals_:
        address = _split_address(local, separator)
        if address is not None and address[1] == port:
            hosts.add(address[0])
    return hosts


def listener_snapshot(port: int, fixture: str = "") -> set[int]:
    """Return every PID holding a TCP LISTEN socket on port.

    Raises OwnershipError when any listening address on the port cannot be
    attributed to a visible process.
    """
    if fixture:
        pids, hosts, system_hosts = _listener_fixture(fixture, port)
    else:
        pids, hosts = _lsof_listeners(port)
        system_hosts = _system_listen_hosts(port)
    if not system_hosts <= hosts:
        raise OwnershipError("a listener on the port is not attributable to a visible process")
    return pids
