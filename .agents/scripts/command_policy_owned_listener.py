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
Every LISTEN address must be attributable (command_policy_listener_table.py),
so other users' sockets hidden from lsof make the port unproven. Sockets are enumerated
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
from pathlib import Path
from typing import Any

from command_policy_listener_table import OwnershipError, listener_snapshot
from command_policy_localdev import HTTP_ENDPOINT_LABELS, LOOPBACK_HOSTS

# Process-table helpers are imported only when roots are supplied, so the base
# command policy keeps working when copied without the process-identity modules.
# Their RuntimeIdentityError is a ValueError and is handled as such below.

_MAX_ROOTS = 64
_MAX_ANCESTRY = 256


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
