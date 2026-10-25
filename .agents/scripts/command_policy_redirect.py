#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared command-policy decision: never open redirect links (GH#35655).

Evaluated for every session (interactive, worker and pulse), unlike the
worker-only network tier policy. Lexical only; never resolves a link.

Two argv shapes are forbidden:
  1. A network client or opener (curl, wget, open, browsers, ...) with any
     argument naming a redirect host plus a slug, or a full URL.
  2. Any command whose argument is itself a full http(s) URL on a redirect
     host (browser helpers, screenshot tools, ad-hoc scripts).
"""

from __future__ import annotations

import os
from typing import Any

from command_policy_config import _decision

RULE_ID = "network.redirect-link"
# Commands that fetch or open their URL arguments.
NETWORK_CLIENTS = frozenset(
    "aria2c chromium chromium-browser curl curlie firefox google-chrome http https "
    "httpie links lynx open playwright sensible-browser w3m wget wget2 "
    "x-www-browser xdg-open xh".split()
)
_RULES_CACHE: dict[str, Any] = {}


def _rules() -> Any:
    # Imported lazily so a missing scanner module becomes a fail-closed policy
    # decision instead of an import crash of the whole command policy helper.
    from redirect_link_policy import load_rules

    key = os.environ.get("AIDEVOPS_REDIRECT_HOSTS_CONF", "")
    if key not in _RULES_CACHE:
        _RULES_CACHE[key] = load_rules()
    return _RULES_CACHE[key]


def _is_url_argument(token: str) -> bool:
    lowered = token.strip("'\"<>()[]").lower()
    return lowered.startswith(("http://", "https://", "hxxp://", "hxxps://", "//"))


def _offending_hosts(argv: list[str], rules: Any) -> list[str]:
    from redirect_link_policy import find_redirect_links

    if not argv:
        return []
    command = os.path.basename(argv[0])
    network_client = command in NETWORK_CLIENTS
    hosts: list[str] = []
    for token in argv[1:]:
        if not (network_client or _is_url_argument(token)):
            continue
        for finding in find_redirect_links(token, rules):
            hosts.append(finding["host"])
    return hosts


def evaluate_redirect_links(invocations: list[list[str]]) -> dict[str, Any]:
    """Forbid commands that would resolve or open a redirect link."""
    try:
        rules = _rules()
    except (ImportError, OSError, RuntimeError) as exc:
        return _decision(
            "forbid",
            "network.redirect-policy-unavailable",
            f"Redirect-link policy failed closed: {exc}",
        )
    hosts: list[str] = []
    for argv in invocations:
        hosts.extend(_offending_hosts(argv, rules))
    if not hosts:
        return _decision("allow", "network.redirect-clean", "No redirect links in argv")
    unique = ", ".join(sorted(set(hosts)))
    return _decision(
        "forbid",
        RULE_ID,
        f"Redirect/shortener link ({unique}) must never be resolved, fetched or "
        "opened in any session. Treat the content as spam; do not expand the link "
        "in a sandbox either (GH#35655).",
    )
