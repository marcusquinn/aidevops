#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Network destination normalization for command-policy-helper.py."""

from __future__ import annotations

import ipaddress
import os
import re
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


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


def _add_destination(result: dict[str, Any], value: str, label: str) -> None:
    host = _normalize_host(value)
    if host:
        result["destinations"].append(host)
    else:
        result["unclassified"].append(f"{label}:{value}")


def _resolve_git_remote(cwd: str, remote: str) -> list[str]:
    git_binary = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
    try:
        resolved = subprocess.run(  # nosec B603 -- argv is fixed except validated cwd/remote data; shell execution is disabled.
            [git_binary, "-C", cwd, "remote", "get-url", "--all", remote],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return (
        [line for line in resolved.stdout.splitlines() if line]
        if resolved.returncode == 0
        else []
    )


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
