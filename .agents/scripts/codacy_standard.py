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
from dataclasses import dataclass

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


def build_request(method, path, body, params):
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("api-token", token())
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return req


def send(req, label):
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise CodacyError(f"{label} -> HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise CodacyError(f"{label} failed: {exc.reason}") from exc


def call(method, path, body=None, params=None):
    """Return decoded JSON (or None for empty bodies)."""
    raw = send(build_request(method, path, body, params), f"{method} {path}")
    return json.loads(raw) if raw.strip() else None


def paged(path, params=None):
    """Collect `data` across pagination.cursor pages."""
    items = []
    query = {"limit": PAGE_LIMIT, **(params or {})}
    while True:
        page = call("GET", path, params=query) or {}
        items.extend(page.get("data", []))
        cursor = (page.get("pagination") or {}).get("cursor")
        if not cursor:
            return items
        query["cursor"] = cursor


def org_base(org):
    return f"/organizations/{PROVIDER}/{urllib.parse.quote(org)}"


def standards_path(org, *parts):
    return "/".join([org_base(org), "coding-standards", *[str(p) for p in parts]])


def organizations():
    return [o["name"] for o in paged("/user/organizations")]


def standards(org):
    return paged(standards_path(org))


def standard_tools(org, std_id):
    return paged(standards_path(org, std_id, "tools"))


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
        if wanted in (str(tool_uuid(tool)).lower(), str(tool.get("name", "")).lower()):
            return tool
    raise CodacyError(f"tool not found in standard: {ref}")


def pattern_id(pattern):
    return pattern.get("id") or pattern["patternDefinition"]["id"]


def enabled_patterns(org, std_id, uuid):
    found = paged(standards_path(org, std_id, "tools", uuid, "patterns"), {"enabled": "true"})
    return {pattern_id(p) for p in found}


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
    empty = (False, set())
    tool_changes, pattern_changes = {}, {}
    for uuid in sorted(set(before) | set(after)):
        b_on, b_pat = before.get(uuid, empty)
        a_on, a_pat = after.get(uuid, empty)
        if b_on != a_on:
            tool_changes[uuid] = (b_on, a_on)
        if b_pat != a_pat:
            pattern_changes[uuid] = (sorted(a_pat - b_pat), sorted(b_pat - a_pat))
    return tool_changes, pattern_changes


def language_name(lang):
    return lang.get("language", lang) if isinstance(lang, dict) else lang


def source_languages(org, std_id):
    detail = call("GET", standards_path(org, std_id)) or {}
    data = detail.get("data", detail)
    langs = data.get("languages") or (data.get("meta") or {}).get("languages") or []
    return [language_name(lang) for lang in langs]


def linked_repositories(org, std_id):
    try:
        repos = paged(standards_path(org, std_id, "repositories"))
    except CodacyError:
        return []
    return [r.get("name", "?") for r in repos]


def repo_tool_state(org, repo, uuid):
    base = f"/analysis/organizations/{PROVIDER}/{urllib.parse.quote(org)}"
    path = f"{base}/repositories/{urllib.parse.quote(repo)}/tools"
    for tool in (call("GET", path) or {}).get("data", []):
        if tool_uuid(tool) == uuid:
            return tool_enabled(tool)
    return None


def state_word(value):
    return {True: "on", False: "off", None: "n/a"}[value]


def tool_label(tools, ref):
    """Return (uuid, label) for the requested tool in one standard."""
    try:
        tool = resolve_tool(tools, ref)
    except CodacyError:
        return None, f"{ref}=absent"
    return tool_uuid(tool), f"{tool.get('name')}={state_word(tool_enabled(tool))}"


def print_standard(org, std, tool_ref):
    std_id = std["id"]
    repos = linked_repositories(org, std_id)
    uuid, label = tool_label(standard_tools(org, std_id), tool_ref)
    print(
        f"  {std_id} {std.get('name', '?')!r} isDefault={std.get('isDefault')} "
        f"draft={std.get('isDraft')} repos={len(repos)} {label}".rstrip()
    )
    for repo in repos:
        suffix = f" effective={state_word(repo_tool_state(org, repo, uuid))}" if uuid else ""
        print(f"      {repo}{suffix}")


def cmd_list(args):
    for org in [args.org] if args.org else organizations():
        print(f"== {org}")
        for std in standards(org):
            print_standard(org, std, args.tool)
    return 0


def delete_draft(org, draft_id):
    try:
        call("DELETE", standards_path(org, draft_id))
        print(f"draft {draft_id} deleted")
    except CodacyError as exc:
        print(f"WARNING: could not delete draft {draft_id}: {exc}", file=sys.stderr)


def draft_id_of(created):
    data = (created or {}).get("data", created or {})
    return data.get("id") or (data.get("meta") or {}).get("id")


def create_draft(org, source):
    body = {
        "name": f"{source.get('name', 'standard')} (draft)",
        "languages": source_languages(org, source["id"]),
    }
    created = call("POST", standards_path(org), body=body,
                   params={"sourceCodingStandard": source["id"]})
    draft = draft_id_of(created)
    if not draft:
        raise CodacyError("draft creation returned no id")
    return draft


@dataclass
class Change:
    """One requested tool change on one source standard."""

    org: str
    source: dict
    uuid: str
    enabled: bool
    promote: bool
    before: dict


def set_draft_tool(change, draft, tool_id, enabled):
    call("PATCH", standards_path(change.org, draft, "tools", tool_id),
         body={"enabled": enabled, "patterns": []})


def copy_enabled_extra(change, tool):
    """True when the copy enabled a tool that was off in the source."""
    was_on = change.before.get(tool_uuid(tool), (False, set()))[0]
    return tool_enabled(tool) and not was_on and tool_uuid(tool) != change.uuid


def repair_draft(change, draft):
    """Disable tools the copy enabled although the source had them off."""
    for tool in standard_tools(change.org, draft):
        if copy_enabled_extra(change, tool):
            print(f"repair: disabling {tool.get('name')} ({tool_uuid(tool)}) enabled by the copy")
            set_draft_tool(change, draft, tool_uuid(tool), False)


def diff_is_exact(change, tool_changes, pattern_changes):
    """Only the requested tool may differ (its patterns follow its state)."""
    expected = {change.uuid: (not change.enabled, change.enabled)}
    return tool_changes == expected and set(pattern_changes) <= {change.uuid}


def apply_draft(change, draft):
    """Edit and verify the draft. Return an exit code, or None once promoted."""
    repair_draft(change, draft)
    set_draft_tool(change, draft, change.uuid, change.enabled)
    tool_changes, pattern_changes = diff(change.before, snapshot(change.org, draft))
    print(f"tool changes: {tool_changes}")
    print(f"pattern changes (added, removed): {pattern_changes}")
    if not diff_is_exact(change, tool_changes, pattern_changes):
        print("REFUSED: draft differs from the requested change; not promoting", file=sys.stderr)
        return 1
    if not change.promote:
        print("dry run: diff equals the requested change")
        return 0
    result = call("POST", standards_path(change.org, draft, "promote"))
    print(f"promoted: {json.dumps(result)}")
    return None


def run_draft(change):
    """Create, repair, edit, diff; promote only an exact diff. Return exit code."""
    draft = create_draft(change.org, change.source)
    print(f"source={change.source['id']} draft={draft}")
    promoted = False
    try:
        code = apply_draft(change, draft)
        promoted = code is None
        return 0 if promoted else code
    finally:
        if not promoted:
            delete_draft(change.org, draft)


def find_source(org, standard_id):
    for std in standards(org):
        if str(std["id"]) == str(standard_id):
            return std
    raise CodacyError(f"standard {standard_id} not found in {org}")


def cmd_set_tool(args):
    enabled = args.enabled == "true"
    source = find_source(args.org, args.standard)
    if source.get("isDraft"):
        raise CodacyError("refusing to edit a draft standard directly; pass a promoted standard id")
    tool = resolve_tool(standard_tools(args.org, source["id"]), args.tool)
    if tool_enabled(tool) == enabled:
        print(f"{tool.get('name')} already {state_word(enabled)} in standard {source['id']}; nothing to do")
        return 0
    before = snapshot(args.org, source["id"])
    return run_draft(Change(args.org, source, tool_uuid(tool), enabled, args.promote, before))


def add_list_parser(sub):
    lst = sub.add_parser("list", help="list standards and tool state per standard and repository")
    lst.add_argument("--org")
    lst.add_argument("--tool", default="Lizard", help="tool name or UUID (default: Lizard)")


def add_set_tool_parser(sub):
    st = sub.add_parser("set-tool", help="enable/disable a tool in a standard via draft, diff, promote")
    st.add_argument("--org", required=True)
    st.add_argument("--standard", required=True)
    st.add_argument("--tool", required=True)
    st.add_argument("--enabled", required=True, choices=["true", "false"])
    st.add_argument("--promote", action="store_true", help="promote when the diff is exact (default: dry run)")


def build_parser():
    parser = argparse.ArgumentParser(prog="codacy-cli.sh standard")
    sub = parser.add_subparsers(dest="action", required=True)
    add_list_parser(sub)
    add_set_tool_parser(sub)
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
