#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tool-call redirect-link decision for runtime hooks (GH#35655, t18771).

Reads a hook payload `{"tool_name": ..., "tool_input": ...}` on stdin and
prints `{"decision": "allow"|"forbid", "reason": ...}`. Exit 0 = allow,
1 = forbid, 2 = error (callers fail closed). Lexical only; never touches the
network and never echoes the matched URL.

Used by the Claude Code PreToolUse hook (hooks/git_safety_guard.py) for
WebFetch and MCP tools. Bash is covered by the shared command policy.
"""

from __future__ import annotations

import json
import sys

from redirect_link_policy import RedirectPolicyError, find_redirect_links, load_rules

URL_SHAPED_MARKERS = ("://", "www.", "hxxp", "[.]", "%2e", "\uff0e", "\u3002")
MAX_STRINGS = 200
MAX_DEPTH = 6


def collect_url_strings(value: object, out: list[str], depth: int = 0) -> list[str]:
    """Collect URL-shaped strings from nested tool arguments."""
    if len(out) >= MAX_STRINGS or depth > MAX_DEPTH:
        return out
    if isinstance(value, str):
        lowered = value.lower()
        if any(marker in lowered for marker in URL_SHAPED_MARKERS):
            out.append(value)
        return out
    if isinstance(value, dict):
        value = list(value.values())
    if isinstance(value, (list, tuple)):
        for item in value:
            collect_url_strings(item, out, depth + 1)
    return out


def decide(payload: dict) -> dict:
    """Return the allow/forbid decision for one hook payload."""
    strings = collect_url_strings(payload.get("tool_input"), [])
    if not strings:
        return {"decision": "allow", "reason": "no URL-shaped arguments"}
    findings = find_redirect_links("\n".join(strings), load_rules())
    if not findings:
        return {"decision": "allow", "reason": "no redirect links"}
    hosts = ", ".join(sorted({item["host"] for item in findings}))
    return {
        "decision": "forbid",
        "reason": (
            f"redirect/shortener link ({hosts}) must never be resolved, fetched or "
            "opened in any session, including remote sandboxes. Treat the source "
            "content as spam (GH#35655)."
        ),
    }


def main() -> int:
    """CLI entry point."""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            raise TypeError("hook payload must be an object")
        result = decide(payload)
    except (OSError, ValueError, TypeError, RedirectPolicyError) as exc:
        print(json.dumps({"decision": "forbid", "reason": f"redirect-link check failed: {exc}"}))
        return 2
    print(json.dumps(result))
    return 0 if result["decision"] == "allow" else 1


if __name__ == "__main__":
    raise SystemExit(main())
