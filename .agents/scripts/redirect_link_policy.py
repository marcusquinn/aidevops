#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic redirect/shortener link detection (GH#35655, t18771).

Strict policy: aidevops never resolves, fetches or opens a URL-shortener or
redirector link, and public contributions containing one are spam. This module
is the single matcher used by the GitHub spam guard, the pulse sweep, the
shared command policy and the OpenCode/Claude Code URL-tool hooks.

Detection is purely lexical. It NEVER performs network I/O: expanding a link
credits the spam campaign and reaches an attacker-controlled endpoint.

Output never echoes the matched URL, only the host and rule, so public CI logs
do not republish spam links.

CLI (exit 0 = clean, 1 = redirect link found, 2 = error):
  redirect_link_policy.py scan [--file PATH] [--strict-bare]   (stdin default)
  redirect_link_policy.py check-url [--strict-bare] URL...
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

CONFIG_ENV = "AIDEVOPS_REDIRECT_HOSTS_CONF"
CONFIG_NAME = "redirect-hosts.conf"

EXIT_CLEAN = 0
EXIT_FOUND = 1
EXIT_ERROR = 2

_ZERO_WIDTH = dict.fromkeys(
    map(ord, "\u00ad\u180e\u200b\u200c\u200d\u200e\u200f\u2060\u2061\u2062\u2063\u2064\ufeff"),
    None,
)
_DOT_VARIANTS = dict.fromkeys(map(ord, "\u3002\uff0e\uff61\u2024\ufe52"), ".")
_DEFANGED_DOT = re.compile(r"\s*[\[\(\{]\s*(?:\.|dot)\s*[\]\)\}]\s*", re.IGNORECASE)
_DEFANGED_SCHEME = re.compile(r"\bhxxp(s?)(?=\[?:)", re.IGNORECASE)
_DEFANGED_COLON = re.compile(r"\[\s*:\s*\]")

# A host-shaped token with optional scheme, userinfo, port and path. Matching
# is done on lowercased, normalized text.
_URL_TOKEN = re.compile(
    r"(?P<scheme>https?:/{0,3}|[a-z][a-z0-9+.\-]*://|//)?"
    r"(?P<userinfo>[^\s/@<>\"'()\[\]{}|]+@)?"
    r"(?P<host>(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9\-]{0,61}[a-z0-9]?)"
    r"(?P<port>:\d{1,5})?"
    r"(?P<rest>[/?#][^\s<>\"'`]*)?"
)
_HOST_BOUNDARY = re.compile(r"[a-z0-9._\-]")


class RedirectPolicyError(RuntimeError):
    """Raised when the redirect host list cannot be loaded."""


@dataclass
class RedirectRules:
    """Parsed redirect-hosts.conf entries."""

    exact: set[str] = field(default_factory=set)
    suffixes: set[str] = field(default_factory=set)
    paths: dict[str, list[str]] = field(default_factory=dict)

    def match(self, host: str, rest: str) -> str | None:
        """Return the matching rule for host+path, or None."""
        host = host.rstrip(".")
        bare = host[4:] if host.startswith("www.") else host
        path = rest.split("?", 1)[0].split("#", 1)[0].rstrip("/")
        for candidate in (host, bare):
            if candidate in self.exact:
                return candidate
            for suffix in self.suffixes:
                if candidate == suffix or candidate.endswith("." + suffix):
                    return f"*.{suffix}"
            for prefix in self.paths.get(candidate, []):
                if path == prefix or path.startswith(prefix + "/"):
                    return f"{candidate}{prefix}"
        return None


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
    for candidate in candidates:
        if candidate.is_file():
            return parse_rules(candidate.read_text(encoding="utf-8"))
    raise RedirectPolicyError(
        f"{CONFIG_NAME} not found (checked: {', '.join(str(c) for c in candidates)})"
    )


def parse_rules(text: str) -> RedirectRules:
    """Parse redirect-hosts.conf content."""
    rules = RedirectRules()
    for raw in text.splitlines():
        entry = raw.split("#", 1)[0].strip().lower()
        if not entry:
            continue
        if entry.startswith("*."):
            rules.suffixes.add(entry[2:])
        elif "/" in entry:
            host, path = entry.split("/", 1)
            rules.paths.setdefault(host, []).append("/" + path.rstrip("/"))
        else:
            rules.exact.add(entry)
    if not (rules.exact or rules.suffixes or rules.paths):
        raise RedirectPolicyError(f"{CONFIG_NAME} contains no entries")
    return rules


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).translate(_ZERO_WIDTH)
    text = text.translate(_DOT_VARIANTS)
    text = _DEFANGED_DOT.sub(".", text)
    text = _DEFANGED_COLON.sub(":", text)
    text = _DEFANGED_SCHEME.sub(r"http\1", text)
    return text.replace("\\", "/").lower()


def _variants(text: str) -> list[str]:
    base = _normalize(text)
    variants = [base]
    for decoded in (unquote(base), _normalize(html.unescape(text)), unquote(_normalize(html.unescape(text)))):
        decoded = _normalize(decoded)
        if decoded not in variants:
            variants.append(decoded)
    return variants


def _qualifies(token: re.Match[str], strict_bare: bool) -> bool:
    """Bare (scheme-less) tokens need a slug path unless strict_bare is set.

    Requiring `host/slug` keeps code such as `s.id`, `x.co` or `u.to` and
    prose mentions of a host from matching, while real short links always
    carry a slug.
    """
    if token.group("scheme") or token.group("host").startswith("www."):
        return True
    rest = token.group("rest") or ""
    if rest.startswith("/") and len(rest.strip("/")) > 0:
        return True
    return strict_bare


def _boundary_ok(text: str, token: re.Match[str]) -> bool:
    start = token.start()
    if start == 0:
        return True
    previous = text[start - 1]
    if token.group("scheme"):
        return not previous.isalnum()
    return not _HOST_BOUNDARY.match(previous)


def find_redirect_links(
    text: str, rules: RedirectRules, strict_bare: bool = False
) -> list[dict[str, str]]:
    """Return unique {host, rule} findings for redirect links in text."""
    findings: dict[tuple[str, str], dict[str, str]] = {}
    if not text:
        return []
    for variant in _variants(text):
        for token in _URL_TOKEN.finditer(variant):
            if not _boundary_ok(variant, token) or not _qualifies(token, strict_bare):
                continue
            host = token.group("host")
            rule = rules.match(host, token.group("rest") or "")
            if rule:
                key = (host, rule)
                findings.setdefault(key, {"host": host, "rule": rule})
    return list(findings.values())


def _emit(findings: list[dict[str, str]]) -> int:
    print(json.dumps({"redirect_links": findings, "count": len(findings)}, sort_keys=True))
    return EXIT_FOUND if findings else EXIT_CLEAN


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="action", required=True)
    scan = sub.add_parser("scan", help="scan text from --file or stdin")
    scan.add_argument("--file", default="")
    scan.add_argument("--strict-bare", action="store_true")
    scan.add_argument("--config", default="")
    check = sub.add_parser("check-url", help="check one or more URLs")
    check.add_argument("urls", nargs="+")
    check.add_argument("--strict-bare", action="store_true")
    check.add_argument("--config", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    args = _parser().parse_args(argv)
    try:
        rules = load_rules(args.config or None)
        if args.action == "scan":
            if args.file:
                text = Path(args.file).read_text(encoding="utf-8", errors="replace")
            else:
                text = sys.stdin.read()
            return _emit(find_redirect_links(text, rules, args.strict_bare))
        findings: list[dict[str, str]] = []
        for url in args.urls:
            findings.extend(find_redirect_links(url, rules, args.strict_bare))
        return _emit(findings)
    except (OSError, RedirectPolicyError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
