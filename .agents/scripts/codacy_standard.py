#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Codacy coding-standard tool management (GH#34183).

Runs the documented procedure from tools/code-review/codacy.md: draft copy,
repair of tools the draft enabled but the source had off, diff, then promote
only when the diff equals the requested change; otherwise delete the draft.

Usage (via codacy-cli.sh standard ...):
    list [--org ORG] [--tool NAME|UUID]
    set-tool --org ORG --standard ID --tool NAME|UUID --enabled true|false [--promote]

The account token is read from CODACY_API_TOKEN (never argv) and sent in the
`api-token` header. Exit codes: 0 ok, 1 failure/refused, 2 usage/auth error.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("CODACY_API_URL", "https://app.codacy.com/api/v3")
PROVIDER = "gh"
PAGE_LIMIT = 1000


class CodacyError(Exception):
    """API or procedure failure."""


def token():
    value = os.environ.get("CODACY_API_TOKEN", "")
    if not value:
        raise SystemExit("CODACY_API_TOKEN is not set (use: aidevops secret CODACY_API_TOKEN -- ...)")
    return value


def call(method, path, body=None, params=None):
    """Return decoded JSON (or None for empty bodies)."""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("api-token", token())
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise CodacyError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise CodacyError(f"{method} {path} failed: {exc.reason}") from exc
    return json.loads(raw) if raw.strip() else None


def paged(path, params=None):
    """Collect `data` across pagination.cursor pages."""
    items = []
    query = dict(params or {})
    query.setdefault("limit", PAGE_LIMIT)
    while True:
        page = call("GET", path, params=query) or {}
        items.extend(page.get("data", []))
        cursor = (page.get("pagination") or {}).get("cursor")
        if not cursor:
            return items
        query["cursor"] = cursor


def org_base(org):
    return f"/organizations/{PROVIDER}/{urllib.parse.quote(org)}"


def organizations():
    return [o["name"] for o in paged("/user/organizations")]


def standards(org):
    return paged(org_base(org) + "/coding-standards")


def standard_tools(org, std_id):
    return paged(f"{org_base(org)}/coding-standards/{std_id}/tools")


def tool_enabled(tool):
    for key in ("isEnabled", "enabled"):
        if key in tool:
            return bool(tool[key])
    return False


def tool_uuid(tool):
    return tool.get("uuid") or tool.get("id")


def resolve_tool(tools, ref):
    """Match a tool by UUID or case-insensitive name."""
    wanted = ref.lower()
    for tool in tools:
        name = str(tool.get("name", "")).lower()
        if str(tool_uuid(tool)).lower() == wanted or name == wanted:
            return tool
    raise CodacyError(f"tool not found in standard: {ref}")


def enabled_patterns(org, std_id, uuid):
    path = f"{org_base(org)}/coding-standards/{std_id}/tools/{uuid}/patterns"
    found = paged(path, {"enabled": "true"})
    return {p.get("id") or p["patternDefinition"]["id"] for p in found}


def snapshot(org, std_id):
    """Map tool uuid -> (enabled, set of enabled pattern ids)."""
    snap = {}
    for tool in standard_tools(org, std_id):
        uuid = tool_uuid(tool)
        on = tool_enabled(tool)
        snap[uuid] = (on, enabled_patterns(org, std_id, uuid) if on else set())
    return snap


def diff(before, after):
    """Return (tool state changes, pattern changes) between two snapshots."""
    tool_changes, pattern_changes = {}, {}
    for uuid in sorted(set(before) | set(after)):
        b_on, b_pat = before.get(uuid, (False, set()))
        a_on, a_pat = after.get(uuid, (False, set()))
        if b_on != a_on:
            tool_changes[uuid] = (b_on, a_on)
        if b_pat != a_pat:
            pattern_changes[uuid] = (sorted(a_pat - b_pat), sorted(b_pat - a_pat))
    return tool_changes, pattern_changes


def source_languages(org, std_id):
    detail = call("GET", f"{org_base(org)}/coding-standards/{std_id}") or {}
    data = detail.get("data", detail)
    langs = data.get("languages") or (data.get("meta") or {}).get("languages") or []
    return [lang.get("language", lang) if isinstance(lang, dict) else lang for lang in langs]


def linked_repositories(org, std_id):
    try:
        repos = paged(f"{org_base(org)}/coding-standards/{std_id}/repositories")
    except CodacyError:
        return []
    return [r.get("name", "?") for r in repos]


def repo_tool_state(org, repo, uuid):
    path = f"/analysis/organizations/{PROVIDER}/{urllib.parse.quote(org)}/repositories/{urllib.parse.quote(repo)}/tools"
    for tool in (call("GET", path) or {}).get("data", []):
        if tool_uuid(tool) == uuid:
            return tool_enabled(tool)
    return None


def state_word(value):
    return {True: "on", False: "off", None: "n/a"}[value]


def cmd_list(args):
    orgs = [args.org] if args.org else organizations()
    for org in orgs:
        print(f"== {org}")
        for std in standards(org):
            std_id = std["id"]
            repos = linked_repositories(org, std_id)
            tools = standard_tools(org, std_id)
            line = f"  {std_id} {std.get('name', '?')!r} isDefault={std.get('isDefault')} draft={std.get('isDraft')} repos={len(repos)}"
            uuid = None
            if args.tool:
                try:
                    tool = resolve_tool(tools, args.tool)
                    uuid = tool_uuid(tool)
                    line += f" {tool.get('name')}={state_word(tool_enabled(tool))}"
                except CodacyError:
                    line += f" {args.tool}=absent"
            print(line)
            for repo in repos:
                effective = repo_tool_state(org, repo, uuid) if uuid else None
                suffix = f" effective={state_word(effective)}" if uuid else ""
                print(f"      {repo}{suffix}")
    return 0


def delete_draft(org, draft_id):
    try:
        call("DELETE", f"{org_base(org)}/coding-standards/{draft_id}")
        print(f"draft {draft_id} deleted")
    except CodacyError as exc:
        print(f"WARNING: could not delete draft {draft_id}: {exc}", file=sys.stderr)


def create_draft(org, source):
    langs = source_languages(org, source["id"])
    body = {"name": f"{source.get('name', 'standard')} (draft)", "languages": langs}
    created = call(
        "POST", f"{org_base(org)}/coding-standards",
        body=body, params={"sourceCodingStandard": source["id"]},
    )
    data = (created or {}).get("data", created or {})
    draft = data.get("id") or (data.get("meta") or {}).get("id")
    if not draft:
        raise CodacyError("draft creation returned no id")
    return draft


def run_draft(org, source, uuid, enabled, before, promote):
    """Create, repair, edit, diff; promote if exact. Return exit code."""
    draft = create_draft(org, source)
    print(f"source={source['id']} draft={draft}")
    try:
        # Repair the documented trap: tools off in source but on in the draft.
        for tool in standard_tools(org, draft):
            t_uuid = tool_uuid(tool)
            was_on = before.get(t_uuid, (False, set()))[0]
            if tool_enabled(tool) and not was_on and t_uuid != uuid:
                print(f"repair: disabling {tool.get('name')} ({t_uuid}) enabled by the copy")
                call("PATCH", f"{org_base(org)}/coding-standards/{draft}/tools/{t_uuid}",
                     body={"enabled": False, "patterns": []})
        call("PATCH", f"{org_base(org)}/coding-standards/{draft}/tools/{uuid}",
             body={"enabled": enabled, "patterns": []})
        tool_changes, pattern_changes = diff(before, snapshot(org, draft))
        print(f"tool changes: {tool_changes}")
        print(f"pattern changes (added, removed): {pattern_changes}")
        expected = {uuid: (not enabled, enabled)}
        # Toggling a tool changes its enabled patterns: only that tool may differ.
        if tool_changes != expected or set(pattern_changes) - {uuid}:
            print("REFUSED: draft differs from the requested change; not promoting", file=sys.stderr)
            delete_draft(org, draft)
            return 1
        if not promote:
            print("dry run: diff equals the requested change")
            delete_draft(org, draft)
            return 0
        result = call("POST", f"{org_base(org)}/coding-standards/{draft}/promote")
        print(f"promoted: {json.dumps(result)}")
        return 0
    except BaseException:
        delete_draft(org, draft)
        raise


def cmd_set_tool(args):
    enabled = args.enabled == "true"
    source = next((s for s in standards(args.org) if str(s["id"]) == str(args.standard)), None)
    if source is None:
        raise CodacyError(f"standard {args.standard} not found in {args.org}")
    if source.get("isDraft"):
        raise CodacyError("refusing to edit a draft/non-source standard directly; pass a promoted standard id")
    tool = resolve_tool(standard_tools(args.org, source["id"]), args.tool)
    uuid = tool_uuid(tool)
    if tool_enabled(tool) == enabled:
        print(f"{tool.get('name')} already {state_word(enabled)} in standard {source['id']}; nothing to do")
        return 0
    before = snapshot(args.org, source["id"])
    return run_draft(args.org, source, uuid, enabled, before, args.promote)


def build_parser():
    parser = argparse.ArgumentParser(prog="codacy-cli.sh standard")
    sub = parser.add_subparsers(dest="action", required=True)
    lst = sub.add_parser("list", help="list standards and tool state per standard and repository")
    lst.add_argument("--org")
    lst.add_argument("--tool", default="Lizard", help="tool name or UUID (default: Lizard)")
    st = sub.add_parser("set-tool", help="enable/disable a tool in a standard via draft, diff, promote")
    st.add_argument("--org", required=True)
    st.add_argument("--standard", required=True)
    st.add_argument("--tool", required=True)
    st.add_argument("--enabled", required=True, choices=["true", "false"])
    st.add_argument("--promote", action="store_true", help="promote when the diff is exact (default: dry run)")
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return cmd_list(args) if args.action == "list" else cmd_set_tool(args)
    except CodacyError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
