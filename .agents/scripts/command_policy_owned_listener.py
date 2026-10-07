#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Worker-owned loopback listener matching for worker HTTP verification.

#aidevops:trust-boundary — owned roots are supplied by the OpenCode plugin
host from its own bounded-operation table (supervisor PID plus start identity
captured at spawn), never from the checked command, its environment or the
worker's files. A loopback HTTP endpoint is allowed only when every TCP
listener on its port descends from one of those live supervisors, each root is
still the same process generation and a direct child of the verified runtime.
lsof attributes listeners; netstat/ss must show no LISTEN address on the port
that lsof could not attribute (other users' sockets). Sockets are enumerated
before and after the process snapshot and must match. Any missing, stale or
contradictory evidence yields no allowance, so operator services (OpenCode
server, MCPs, webhook receivers, model servers) stay denied.

Residual limits: this is a pre-execution check, so a listener could change
between the check and the client's connect; SO_REUSEPORT sharing of the same
address by a hidden socket is not distinguishable. Whole-process enforcement
remains the egress backend's job.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess  # nosec B404 -- fixed lsof argv, no shell.
from pathlib import Path
from typing import Any

from command_policy_localdev import HTTP_ENDPOINT_LABELS, LOOPBACK_HOSTS

# Process-table helpers are imported only when roots are supplied, so the base
# command policy keeps working when copied without the process-identity modules.
# Their RuntimeIdentityError is a ValueError and is handled as such below.

_MAX_ROOTS = 64
_MAX_ANCESTRY = 256


class OwnershipError(ValueError):
    """Raised when listener ownership cannot be proven."""


def parse_roots(value: str) -> list[tuple[int, str]]:
    """Parse the plugin-supplied JSON root list into (pid, identity) pairs."""
    if not value:
        return []
    try:
        payload = json.loads(value)
    except json.JSONDecodeError as exc:
        raise OwnershipError("owned listener roots are malformed") from exc
    if not isinstance(payload, list) or len(payload) > _MAX_ROOTS:
        raise OwnershipError("owned listener roots are malformed")
    roots = []
    for entry in payload:
        pid = entry.get("pid") if isinstance(entry, dict) else None
        identity = entry.get("identity") if isinstance(entry, dict) else None
        if not isinstance(pid, int) or pid <= 1 or not isinstance(identity, str) or not identity.strip():
            raise OwnershipError("owned listener roots are malformed")
        roots.append((pid, " ".join(identity.split())))
    return roots


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
    """Return every LISTEN address on port, visible regardless of socket owner.

    lsof only attributes sockets of processes the caller may inspect; netstat
    (macOS/BSD) and ss (Linux) list all sockets without attribution. Any
    address lsof could not attribute makes ownership unproven.
    """
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


def _verified_roots(
    records: list[Any], runtime_pid: int, runtime_identity: str, roots: list[tuple[int, str]]
) -> set[int]:
    from process_termination_identity import _runtime_lineage

    _runtime_lineage(records, runtime_pid, runtime_identity)
    by_pid = {record.pid: record for record in records}
    verified = set()
    for pid, identity in roots:
        record = by_pid.get(pid)
        if record is None or record.start != identity or record.ppid != runtime_pid:
            continue
        verified.add(pid)
    return verified


def _descends_from(pid: int, roots: set[int], by_pid: dict[int, Any]) -> bool:
    current = by_pid.get(pid)
    if current is None or current.pid in roots:
        return False
    for _ in range(_MAX_ANCESTRY):
        if current.ppid in roots:
            return True
        parent = by_pid.get(current.ppid)
        if parent is None or current.ppid <= 1:
            return False
        current = parent
    return False


class OwnedListenerProof:
    """Listener-ownership evidence for one policy check."""

    def __init__(self, options: dict[str, Any]) -> None:
        self.roots = parse_roots(str(options.get("roots", "")))
        self.runtime_pid = int(options.get("runtime_pid") or 0)
        self.runtime_identity = str(options.get("runtime_identity", ""))
        self.process_table_fixture = str(options.get("process_table_fixture", ""))
        self.listener_table_fixture = str(options.get("listener_table_fixture", ""))

    def _process_context(self) -> tuple[set[int], dict[int, Any]]:
        from process_termination_identity import _load_fixture, _load_live_processes

        fixture = self.process_table_fixture
        records = _load_fixture(Path(fixture)) if fixture else _load_live_processes()
        roots = _verified_roots(records, self.runtime_pid, self.runtime_identity, self.roots)
        return roots, {record.pid: record for record in records}

    def owns_port(self, port: int) -> bool:
        """Return True only when every listener on port is worker-owned.

        Sockets are enumerated before and after a fresh process snapshot and
        must match, so a listener PID cannot be judged by a stale generation.
        """
        if not self.roots:
            return False
        try:
            before = listener_snapshot(port, self.listener_table_fixture)
            if not before:
                return False
            roots, by_pid = self._process_context()
            if not roots or listener_snapshot(port, self.listener_table_fixture) != before:
                return False
        except (ValueError, ImportError):
            return False
        return all(_descends_from(pid, roots, by_pid) for pid in before)


def owned_listener_hosts(
    endpoints: list[dict[str, Any]], http_client: bool, options: dict[str, Any] | None
) -> list[str]:
    """Return loopback hosts whose every endpoint targets a worker-owned listener."""
    if not http_client or not endpoints or not options or not options.get("roots"):
        return []
    try:
        proof = OwnedListenerProof(options)
    except (OwnershipError, TypeError, ValueError):
        return []
    allowed = []
    for host in sorted({endpoint.get("host") for endpoint in endpoints} & LOOPBACK_HOSTS):
        host_endpoints = [endpoint for endpoint in endpoints if endpoint.get("host") == host]
        if all(
            endpoint.get("label") in HTTP_ENDPOINT_LABELS
            and isinstance(endpoint.get("port"), int)
            and proof.owns_port(endpoint["port"])
            for endpoint in host_endpoints
        ):
            allowed.append(host)
    return allowed
