#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Network destination normalization for command-policy-helper.py."""

from __future__ import annotations

import ipaddress
import os
import re
from typing import Any
from urllib.parse import urlsplit

from command_policy_git_query import _run_git_query_detailed


def _normalize_host(value: str) -> str | None:
    candidate = value.strip()
    if not candidate or any(char in candidate for char in "\x00\n\r"):
        return None
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", candidate):
        return _url_host(candidate)
    candidate = _host_candidate(candidate)
    if _is_ip_address(candidate):
        return candidate
    if (
        re.fullmatch(r"[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?", candidate)
        and "." in candidate
    ):
        return candidate
    return None


def _url_host(candidate: str) -> str | None:
    parsed = urlsplit(candidate)
    return parsed.hostname.lower().rstrip(".") if parsed.hostname else None


def _is_ip_address(candidate: str) -> bool:
    try:
        ipaddress.ip_address(candidate)
        return True
    except ValueError:
        return False


def _host_candidate(candidate: str) -> str:
    scp_match = re.match(r"^(?:[^@/:]+@)?(\[[^]]+\]|[^/:]+):.+$", candidate)
    if scp_match and not re.match(r"^[A-Za-z]:[\\/]", candidate):
        candidate = scp_match.group(1).strip("[]").lower().rstrip(".")
    elif "@" in candidate and "/" not in candidate:
        candidate = candidate.rsplit("@", 1)[1]
    return _strip_host_path_and_port(candidate)


def _strip_host_path_and_port(candidate: str) -> str:
    candidate = candidate.split("/", 1)[0]
    if candidate.startswith("[") and "]" in candidate:
        candidate = candidate[1 : candidate.index("]")]
    elif candidate.count(":") == 1:
        candidate = candidate.split(":", 1)[0]
    return candidate.rstrip(".").lower()


_DEFAULT_SCHEME_PORTS = {"http": 80, "https": 443}


def _valid_port(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        port = int(value)
    except (TypeError, ValueError):
        return None
    return port if 0 < port < 65536 else None


def _destination_port(value: str) -> int | None:
    """Return the explicit or scheme-default TCP port, or None when unknown."""
    candidate = value.strip()
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", candidate):
        parsed = urlsplit(candidate)
        try:
            explicit = parsed.port
        except ValueError:
            return None
        return explicit or _DEFAULT_SCHEME_PORTS.get(parsed.scheme.lower())
    match = re.match(r"^(?:\[[^]]+\]|[^/:@\[\]]+):(\d+)(?:[/?#]|$)", candidate)
    return _valid_port(match.group(1)) if match else None


def _add_destination(
    result: dict[str, Any],
    value: str,
    label: str,
    context: dict[str, Any] | None = None,
) -> None:
    """Record a destination; context may carry an explicit port and logical host (via)."""
    host = _normalize_host(value)
    if host:
        result["destinations"].append(host)
        context = context or {}
        port = context.get("port")
        result.setdefault("endpoints", []).append({
            "host": host,
            "label": label,
            "port": port if port is not None else _destination_port(value),
            "via": context.get("via"),
        })
    else:
        result["unclassified"].append(f"{label}:{value}")


def _run_git_query(
    cwd: str, args: list[str], ok_codes: tuple[int, ...] = (0,)
) -> list[str] | None:
    """Run a read-only git query; return stdout lines, or None when it fails."""
    return _run_git_query_detailed(cwd, args, ok_codes)[0]


def _resolve_git_remote(cwd: str, remote: str, include_push: bool = False) -> list[str]:
    """Return a remote's URLs; with include_push, push URLs too or nothing."""
    urls = _run_git_query(cwd, ["remote", "get-url", "--all", remote]) or []
    if not urls or not include_push:
        return urls
    push_urls = _run_git_query(cwd, ["remote", "get-url", "--all", "--push", remote])
    return urls + push_urls if push_urls else []


def _git_effective_cwd(argv: list[str], cwd: str) -> str:
    effective = cwd
    index = 1
    while index < len(argv):
        if argv[index] == "-C" and index + 1 < len(argv):
            target = argv[index + 1]
            effective = (
                target
                if os.path.isabs(target)
                else os.path.abspath(os.path.join(effective, target))
            )
            index += 2
            continue
        if not argv[index].startswith("-"):
            break
        index += 1
    return effective
