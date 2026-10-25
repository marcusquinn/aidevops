#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect/shortener host rules: loading, parsing and matching (GH#35655).

Rules come from configs/redirect-hosts.conf. Entry forms:
  host.tld          exact host (www. prefix also matches)
  *.host.tld        host and every subdomain
  host.tld/path     host plus a path prefix (e.g. google.com/url)

Pure data handling; no network I/O.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_ENV = "AIDEVOPS_REDIRECT_HOSTS_CONF"
CONFIG_NAME = "redirect-hosts.conf"


class RedirectPolicyError(RuntimeError):
    """Raised when the redirect host list cannot be loaded."""


def _matches_suffix(candidate: str, suffix: str) -> bool:
    return candidate == suffix or candidate.endswith("." + suffix)


def _matches_path(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


@dataclass
class RedirectRules:
    """Parsed redirect-hosts.conf entries."""

    exact: set[str] = field(default_factory=set)
    suffixes: set[str] = field(default_factory=set)
    paths: dict[str, list[str]] = field(default_factory=dict)

    def _match_candidate(self, candidate: str, path: str) -> str | None:
        if candidate in self.exact:
            return candidate
        suffix = next((s for s in self.suffixes if _matches_suffix(candidate, s)), None)
        if suffix:
            return f"*.{suffix}"
        prefix = next(
            (p for p in self.paths.get(candidate, []) if _matches_path(path, p)), None
        )
        return f"{candidate}{prefix}" if prefix else None

    def match(self, host: str, rest: str) -> str | None:
        """Return the matching rule for host+path, or None."""
        host = host.rstrip(".")
        bare = host[4:] if host.startswith("www.") else host
        path = rest.split("?", 1)[0].split("#", 1)[0].rstrip("/")
        for candidate in (host, bare):
            rule = self._match_candidate(candidate, path)
            if rule:
                return rule
        return None

    def add_entry(self, entry: str) -> None:
        """Add one normalized config entry."""
        if entry.startswith("*."):
            self.suffixes.add(entry[2:])
        elif "/" in entry:
            host, path = entry.split("/", 1)
            self.paths.setdefault(host, []).append("/" + path.rstrip("/"))
        else:
            self.exact.add(entry)

    def is_empty(self) -> bool:
        """Return whether no rules were loaded."""
        return not (self.exact or self.suffixes or self.paths)


def _config_candidates() -> list[Path]:
    here = Path(__file__).resolve().parent
    candidates = []
    override = os.environ.get(CONFIG_ENV, "")
    if override:
        candidates.append(Path(override))
    candidates.append(here.parent / "configs" / CONFIG_NAME)
    candidates.append(Path.home() / ".aidevops" / "agents" / "configs" / CONFIG_NAME)
    return candidates


def load_rules(path: str | os.PathLike[str] | None = None) -> RedirectRules:
    """Load redirect rules from an explicit path or the standard locations."""
    candidates = [Path(path)] if path else _config_candidates()
    found = next((c for c in candidates if c.is_file()), None)
    if found is None:
        raise RedirectPolicyError(
            f"{CONFIG_NAME} not found (checked: {', '.join(str(c) for c in candidates)})"
        )
    return parse_rules(found.read_text(encoding="utf-8"))


def parse_rules(text: str) -> RedirectRules:
    """Parse redirect-hosts.conf content."""
    rules = RedirectRules()
    for raw in text.splitlines():
        entry = raw.split("#", 1)[0].strip().lower()
        if entry:
            rules.add_entry(entry)
    if rules.is_empty():
        raise RedirectPolicyError(f"{CONFIG_NAME} contains no entries")
    return rules
