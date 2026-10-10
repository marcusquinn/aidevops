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
ORG = "/organizations/gh/{}"


class CodacyError(Exception):
    """API or procedure failure."""


def call(method, path, body=None, params=None):
    """Return decoded JSON (None for an empty body)."""
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data = None if body is None else json.dumps(body).encode()
    headers = {"api-token": os.environ["CODACY_API_TOKEN"], "Accept": "application/json",
               "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
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
    query = {"limit": 1000, **(params or {})}
    items = []
    while True:
        page = call("GET", path, params=query) or {}
        items += page.get("data", [])
        query["cursor"] = page.get("pagination", {}).get("cursor")
        if query["cursor"] is None:
            return items


def std_path(org, *parts):
    return "/".join([ORG.format(urllib.parse.quote(org)), "coding-standards", *map(str, parts)])


def tool_on(tool):
    return bool(tool.get("isEnabled", tool.get("enabled", False)))


def find_tool(tools, ref):
    """Match a tool by UUID or case-insensitive name."""
    wanted = ref.lower()
    found = [t for t in tools if wanted in (t["uuid"].lower(), t.get("name", "").lower())]
    if not found:
        raise CodacyError(f"tool not found in standard: {ref}")
    return found[0]


def snapshot(org, std_id):
    """Map tool uuid -> (enabled, set of enabled pattern ids)."""
    snap = {}
    for tool in paged(std_path(org, std_id, "tools")):
        pats = paged(std_path(org, std_id, "tools", tool["uuid"], "patterns"), {"enabled": "true"})
        snap[tool["uuid"]] = (tool_on(tool), {p.get("id", str(p)) for p in pats} if tool_on(tool) else set())
    return snap


def diff(before, after):
    """Return (tool state changes, pattern changes) between two snapshots."""
    empty = (False, set())
    tools = {u: (before.get(u, empty)[0], after.get(u, empty)[0]) for u in set(before) | set(after)}
    pats = {u: (before.get(u, empty)[1], after.get(u, empty)[1]) for u in tools}
    return ({u: s for u, s in tools.items() if s[0] != s[1]},
            {u: (sorted(a - b), sorted(b - a)) for u, (b, a) in pats.items() if a != b})


def repo_state(org, repo, uuid):
    path = f"/analysis{ORG.format(urllib.parse.quote(org))}/repositories/{urllib.parse.quote(repo)}/tools"
    tools = (call("GET", path) or {}).get("data", [])
    return next((("on" if tool_on(t) else "off") for t in tools if t["uuid"] == uuid), "n/a")


def print_standard(org, std, ref):
    repos = [r["name"] for r in paged(std_path(org, std["id"], "repositories"))]
    try:
        tool = find_tool(paged(std_path(org, std["id"], "tools")), ref)
        label = f"{tool['name']}={'on' if tool_on(tool) else 'off'}"
    except CodacyError:
        tool, label = {"uuid": None}, f"{ref}=absent"
    print(f"  {std['id']} {std.get('name')!r} isDefault={std.get('isDefault')} "
          f"draft={std.get('isDraft')} repos={len(repos)} {label}")
    for repo in repos:
        print(f"      {repo} effective={repo_state(org, repo, tool['uuid'])}")


def cmd_list(args):
    for org in [args.org] if args.org else [o["name"] for o in paged("/user/organizations")]:
        print(f"== {org}")
        for std in paged(std_path(org)):
            print_standard(org, std, args.tool)
    return 0


@dataclass
class Change:
    """One requested tool change on one source standard."""

    org: str
    source: dict
    uuid: str
    enabled: bool
    promote: bool
    before: dict


def set_tool(change, draft, tool_id, enabled):
    call("PATCH", std_path(change.org, draft, "tools", tool_id), body={"enabled": enabled, "patterns": []})


def apply_draft(change, draft):
    """Edit and verify the draft. Return an exit code, or None once promoted."""
    for tool in paged(std_path(change.org, draft, "tools")):
        extra = tool_on(tool) and not change.before.get(tool["uuid"], (False,))[0]
        if extra and tool["uuid"] != change.uuid:
            print(f"repair: disabling {tool.get('name')} ({tool['uuid']}) enabled by the copy")
            set_tool(change, draft, tool["uuid"], False)
    set_tool(change, draft, change.uuid, change.enabled)
    tool_changes, pattern_changes = diff(change.before, snapshot(change.org, draft))
    print(f"tool changes: {tool_changes}\npattern changes (added, removed): {pattern_changes}")
    exact = {change.uuid: (not change.enabled, change.enabled)}
    if tool_changes != exact or not set(pattern_changes) <= {change.uuid}:
        print("REFUSED: draft differs from the requested change; not promoting", file=sys.stderr)
        return 1
    if not change.promote:
        print("dry run: diff equals the requested change")
        return 0
    print(f"promoted: {json.dumps(call('POST', std_path(change.org, draft, 'promote')))}")
    return None


def run_draft(change):
    """Create a draft copy, apply and check it, delete it unless promoted."""
    source = change.source
    langs = (call("GET", std_path(change.org, source["id"])) or {}).get("data", {}).get("languages", [])
    body = {"name": f"{source.get('name', 'standard')} (draft)",
            "languages": [x.get("language", x) if isinstance(x, dict) else x for x in langs]}
    created = call("POST", std_path(change.org), body=body, params={"sourceCodingStandard": source["id"]})
    draft = created["data"]["id"]
    print(f"source={source['id']} draft={draft}")
    promoted = False
    try:
        code = apply_draft(change, draft)
        promoted = code is None
        return code or 0
    finally:
        if not promoted:
            try:
                call("DELETE", std_path(change.org, draft))
                print(f"draft {draft} deleted")
            except CodacyError as exc:
                print(f"WARNING: could not delete draft {draft}: {exc}", file=sys.stderr)


def cmd_set_tool(args):
    enabled = args.enabled == "true"
    source = next((s for s in paged(std_path(args.org)) if str(s["id"]) == args.standard), None)
    if source is None or source.get("isDraft"):
        raise CodacyError(f"standard {args.standard} not found in {args.org}, or it is a draft")
    tool = find_tool(paged(std_path(args.org, source["id"], "tools")), args.tool)
    if tool_on(tool) == enabled:
        print(f"{tool['name']} already {'on' if enabled else 'off'} in standard {source['id']}; nothing to do")
        return 0
    before = snapshot(args.org, source["id"])
    return run_draft(Change(args.org, source, tool["uuid"], enabled, args.promote, before))


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
    if "CODACY_API_TOKEN" not in os.environ:
        print("CODACY_API_TOKEN is not set (use: aidevops secret CODACY_API_TOKEN -- ...)", file=sys.stderr)
        return 2
    try:
        return cmd_list(args) if args.action == "list" else cmd_set_tool(args)
    except (CodacyError, KeyError) as exc:
        print(f"ERROR: {exc!r}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
