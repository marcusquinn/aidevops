#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Input validation and network analyzer dispatch."""

from __future__ import annotations

import os
from typing import Any

from command_policy_git import _analyze_git
from command_policy_http import _analyze_curl
from command_policy_network import _add_destination
from command_policy_transport import _analyze_scp, _analyze_ssh
from command_policy_wget import _analyze_wget


class CommandParseError(ValueError):
    """Raised when shell syntax cannot be represented as deterministic argv."""


def _validate_argv(value: Any) -> list[str]:
    if not isinstance(value, list) or not value:
        raise CommandParseError("argv must be a non-empty JSON array")
    if not all(isinstance(arg, str) for arg in value):
        raise CommandParseError("every argv element must be a string")
    if any("\x00" in arg for arg in value):
        raise CommandParseError("argv cannot contain NUL bytes")
    return value


def analyze_network_argv(argv: list[str], cwd: str) -> dict[str, Any]:
    exact = _validate_argv(argv)
    executable = os.path.basename(exact[0]).lower()
    result: dict[str, Any] = {
        "recognized": False,
        "requires_destination": True,
        "destinations": [],
        "unclassified": [],
    }
    if executable == "curl":
        result["recognized"] = True
        _analyze_curl(exact, result)
    elif executable == "wget":
        result["recognized"] = True
        _analyze_wget(exact, result)
    elif executable == "ssh":
        result["recognized"] = True
        _analyze_ssh(exact, result)
    elif executable == "scp":
        result["recognized"] = True
        _analyze_scp(exact, result)
    elif executable == "git":
        result["recognized"] = _analyze_git(exact, cwd, result)
    elif executable in {"dig", "nslookup", "host"}:
        result["recognized"] = True
        candidates = [
            arg for arg in exact[1:] if not arg.startswith(("-", "+", "@"))
        ]
        if not candidates:
            result["unclassified"].append("dns-query-destination-missing")
        else:
            _add_destination(result, candidates[0], "dns-query")
    result["destinations"] = sorted(set(result["destinations"]))
    return result
