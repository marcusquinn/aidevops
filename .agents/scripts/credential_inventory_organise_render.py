#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Text rendering for `aidevops secret organise` plans (GH#34723).

Lines use `NAME  -> detail` rather than `NAME: detail` so transcript
redactors that mask the word after `*_TOKEN:` do not hide the plan.
"""

from __future__ import annotations

from typing import Any


def _used(counts: dict[str, dict] | None, name: str) -> str:
    if counts is None:
        return ""
    item = counts.get(name) or {}
    dynamic = f", {item['possible_dynamic']} possible-dynamic" if item.get("possible_dynamic") else ""
    return f"  [{item.get('literal', 0)} reference(s){dynamic}]"


def _render_drafts(result: dict[str, Any], counts: dict | None) -> list[str]:
    if not result["drafts"]:
        return []
    lines = [f"\nDraft records ({len(result['drafts'])}, unconfirmed; write with --apply-drafts):"]
    for draft in result["drafts"]:
        account = draft.get("account_ref") or (f"tag {draft['account_hint']}?" if draft.get("account_hint") else "unknown")
        lines.append(f"  {draft['name']}  -> {draft['provider']}, kind {draft['kind'] or '?'}, account {account}{_used(counts, draft['name'])}")
        if draft.get("note"):
            lines.append(f"      note {draft['note']}")
    return lines


def _render_aliases(result: dict[str, Any], counts: dict | None) -> list[str]:
    if not result["aliases"]:
        return []
    lines = ["\nDuplicate or overlapping tokens (aliases, never renames):"]
    for item in result["aliases"]:
        if item["action"] != "alias":
            lines.append(f"  review {' / '.join(item['credentials'])}  -> overlapping reach {item['shared']}")
            continue
        lines.append(f"  keep {item['keep']}{_used(counts, item['keep'])}, retire {item['retire']}"
                     f"{_used(counts, item['retire'])}; identical reach {item['shared']}")
        lines += [f"      {number}. {step}" for number, step in enumerate(item["steps"], 1)]
    return lines


def _render_defaults(result: dict[str, Any]) -> list[str]:
    if not result["defaults"]:
        return []
    lines = ["\nDefault decisions needed:"]
    for item in result["defaults"]:
        bare = " (bare variable stored directly)" if item["stored_bare_variable"] else ""
        lines.append(f"  {item['provider']} ({item['variable']}){bare}, choose one:")
        lines += [f"      {command}" for command in item["commands"]]
    return lines


def _render_recorded(result: dict[str, Any], counts: dict | None) -> list[str]:
    if counts is None:
        return []
    drafted = {draft["name"] for draft in result["drafts"]}
    lines = ["\nRecorded credentials:"] + [f"  {name}{_used(counts, name)}" for name in sorted(counts) if name not in drafted]
    if not result["dependents_complete"]:
        lines.append("  (some sources were skipped; run `aidevops secret dependents NAME` before changing any name)")
    return lines


def render(result: dict[str, Any]) -> str:
    counts = result["dependents"]
    lines = ["Credential organisation plan (nothing is renamed, deleted or re-pointed)"]
    lines += _render_drafts(result, counts)
    if result["unrecognised"]:
        lines.append("\nUnrecognised (record manually): " + ", ".join(result["unrecognised"]))
    if result["accounts"]:
        lines.append("\nAccount refs from verified account names:")
        lines += [f"  {item['credential']}  -> {item['account_ref']} ({item['account_name']}{', exists' if item['exists'] else ', new'})"
                  for item in result["accounts"]]
    lines += _render_aliases(result, counts) + _render_defaults(result) + _render_recorded(result, counts)
    if result["stored_listing"] != "ok":
        lines.append("\nStored-secret listing unavailable; undescribed secrets were not checked.")
    return "\n".join(lines)
