#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Registered local-hosting site matching for worker HTTP verification.

#aidevops:trust-boundary — the local-hosting registry is operator-owned state
under the real home directory, read from the policy process environment. Only
the worker repository's own registered app is eligible, only for HTTP clients,
and only on the registered host:port pairs. Unregistered loopback ports and all
other raw IPs stay denied by network-tier-helper.sh.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

from command_policy_network import _run_git_query, _valid_port

LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})
PROXY_PORTS = frozenset({80, 443})
HTTP_ENDPOINT_LABELS = frozenset(
    {"url", "--url", "resolve-host", "resolve-address", "connect-source", "connect-target"}
)
_LOCAL_DOMAIN = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.(?:local|localhost)$")
_MAX_REGISTRY_BYTES = 4 * 1024 * 1024


def registry_path() -> Path:
    """Return the local-hosting registry path for the policy process."""
    override = os.environ.get("AIDEVOPS_LOCALDEV_REGISTRY", "")
    if override:
        return Path(override)
    home = os.environ.get("REAL_HOME") or os.environ.get("HOME") or str(Path.home())
    return Path(home) / ".local-dev-proxy" / "ports.json"


def _sanitize_name(value: str) -> str:
    name = value.rsplit("/", 1)[-1].lower()
    name = re.sub(r"[^a-z0-9-]", "-", name)
    return re.sub(r"-+", "-", name).strip("-")


def _main_worktree(cwd: str) -> Path | None:
    lines = _run_git_query(cwd, ["worktree", "list", "--porcelain"]) or []
    if not lines or not lines[0].startswith("worktree "):
        return None
    return Path(lines[0][len("worktree ") :])


def _package_name(main_worktree: Path) -> str:
    package = main_worktree / "package.json"
    try:
        data = json.loads(package.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    name = data.get("name") if isinstance(data, dict) else None
    return name if isinstance(name, str) else ""


def repo_app_names(cwd: str) -> set[str]:
    """Return localdev app names for the repository containing cwd.

    Names come from the canonical (main) worktree, which workers do not edit:
    its package.json name and its directory basename, matching
    localdev-helper-ports.sh infer_project_name().
    """
    main_worktree = _main_worktree(cwd)
    if main_worktree is None:
        return set()
    names = {_sanitize_name(_package_name(main_worktree)), _sanitize_name(main_worktree.name)}
    names.discard("")
    return names


def _load_apps() -> dict[str, Any]:
    path = registry_path()
    try:
        if not path.is_file() or path.stat().st_size > _MAX_REGISTRY_BYTES:
            return {}
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    apps = data.get("apps") if isinstance(data, dict) else None
    return apps if isinstance(apps, dict) else {}


def _local_domain(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    domain = value.strip().lower().rstrip(".")
    return domain if _LOCAL_DOMAIN.match(domain) else None


def _collect_app(app: Any, domains: set[str], ports: set[int]) -> None:
    if not isinstance(app, dict):
        return
    port = _valid_port(app.get("port"))
    if port is not None:
        ports.add(port)
    domain = _local_domain(app.get("domain"))
    if domain:
        domains.add(domain)
    branches = app.get("branches")
    if not isinstance(branches, dict):
        return
    for branch in branches.values():
        if not isinstance(branch, dict):
            continue
        branch_port = _valid_port(branch.get("port"))
        if branch_port is not None:
            ports.add(branch_port)
        subdomain = _local_domain(branch.get("subdomain"))
        if subdomain:
            domains.add(subdomain)


def registered_sites(cwd: str) -> tuple[set[str], set[int]]:
    """Return (local domains, loopback app ports) registered for cwd's repo."""
    apps = _load_apps()
    domains: set[str] = set()
    ports: set[int] = set()
    if not apps:
        return domains, ports
    for name in repo_app_names(cwd):
        _collect_app(apps.get(name), domains, ports)
    return domains, ports


def _endpoint_allowed(endpoint: dict[str, Any], domains: set[str], ports: set[int]) -> bool:
    host = endpoint.get("host")
    port = endpoint.get("port")
    if endpoint.get("label") not in HTTP_ENDPOINT_LABELS or port is None:
        return False
    if host in domains:
        return port in PROXY_PORTS
    if host not in LOOPBACK_HOSTS:
        return False
    if port in ports:
        return True
    return port in PROXY_PORTS and endpoint.get("via") in domains


def local_site_hosts(endpoints: list[dict[str, Any]], cwd: str, http_client: bool) -> list[str]:
    """Return hosts whose every endpoint is a registered local site for cwd's repo."""
    if not http_client or not endpoints:
        return []
    candidates = {
        endpoint.get("host")
        for endpoint in endpoints
        if endpoint.get("host") in LOOPBACK_HOSTS
        or _local_domain(endpoint.get("host")) is not None
    }
    if not candidates:
        return []
    domains, ports = registered_sites(cwd)
    if not domains and not ports:
        return []
    allowed = []
    for host in sorted(candidates):
        host_endpoints = [endpoint for endpoint in endpoints if endpoint.get("host") == host]
        if all(_endpoint_allowed(endpoint, domains, ports) for endpoint in host_endpoints):
            allowed.append(host)
    return allowed
