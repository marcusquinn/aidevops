#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only background readiness of fleet repositories.

For each repository in a fleet plan, checks GitHub facts (private visibility,
owner, push permission, default-branch head), the local clone (origin identity,
remote-tracking default branch), effective project config (the untracked
.aidevops.json that native gates read, not the registry's feature labels) and
registry automation flags (Pulse and maintenance). Collectors live in
hosting_fleet_checks.py.

This is configured readiness. It does not prove a worker has run successfully;
--worker-evidence adds the most recent merged worker PR as separate evidence.
Nothing here writes to GitHub, clones, the registry or project config.
"""

from __future__ import annotations

import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_checks import (  # noqa: E402
    automation_problems,
    clone_facts,
    config_facts,
    gh_actor,
    remote_facts,
    worker_evidence,
)
from hosting_fleet_plan import CLEAN_STATES  # noqa: E402
from repo_layout_migrate import canonical_bytes, expand_path, load_json, sha256_bytes  # noqa: E402

READY_SCHEMA = "aidevops-hostinger-fleet-readiness/v1"
MAX_WORKERS = 6
REPAIR_HINT = "aidevops project-config restore {slug}  (preview; --apply needs a terminal)"


def repo_groups(plan: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """One readiness subject per repository slug, carrying every domain it serves."""
    groups: dict[str, dict[str, Any]] = {}
    for item in plan["sites"]:
        slug = item.get("expected_slug") or item.get("registered_slug")
        if not slug:
            continue
        group = groups.setdefault(slug, {"slug": slug, "domains": [], "plan_states": set(),
                                         "path": item.get("registered_path") or item.get("expected_path")})
        group["domains"].append(item["domain"])
        group["plan_states"].add(item["state"])
    return groups


def check_repo(group: dict[str, Any], registry: dict[str, Any], evidence: bool) -> dict[str, Any]:
    """Assess one repository; problems block readiness, warnings do not."""
    slug = group["slug"]
    problems = [f"plan-state:{state}" for state in sorted(group["plan_states"]) if state not in CLEAN_STATES]
    # The slug already carries any owner exception, so it is the expected owner.
    remote, remote_problems, warnings = remote_facts(slug, slug.split("/", 1)[0])
    problems += remote_problems
    path = expand_path(group["path"]) if group["path"] else None
    facts: dict[str, Any] = {"remote": remote}
    if path is None:
        problems.append("clone-missing")
    else:
        for collect in (lambda: clone_facts(path, slug, remote), lambda: config_facts(path, registry)):
            found, found_problems, found_warnings = collect()
            facts.update(found)
            problems += found_problems
            warnings += found_warnings
    problems += automation_problems(registry)
    result = {
        "slug": slug,
        "domains": sorted(group["domains"]),
        "path": group["path"],
        "ready": not problems,
        "problems": problems,
        "warnings": sorted(set(warnings)),
        "pulse": registry.get("pulse"),
        "maintenance": registry.get("maintenance") is not False if registry else None,
        **facts,
    }
    if "project-config-missing" in result["warnings"]:
        result["repair"] = REPAIR_HINT.format(slug=slug)
    if evidence:
        result["worker_evidence"] = worker_evidence(slug)
    return result


def build_readiness(plan: dict[str, Any], repos_json: str, *, evidence: bool) -> dict[str, Any]:
    """Assess every plan repository and return a content-hashed readiness receipt."""
    payload = load_json(expand_path(repos_json))
    records = payload.get("initialized_repos", []) if isinstance(payload, dict) else []
    registry = {str(item.get("slug") or "").lower(): item for item in records}
    groups = sorted(repo_groups(plan).values(), key=lambda group: group["slug"])
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        repos = list(pool.map(
            lambda group: check_repo(group, registry.get(group["slug"].lower(), {}), evidence),
            groups,
        ))
    actor = gh_actor()
    ready = sum(1 for item in repos if item["ready"])
    receipt = {
        "schema": READY_SCHEMA,
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "plan_sha256": plan.get("plan_sha256"),
        "owner": plan["owner"],
        "gh_actor": actor,
        "readiness_kind": "configured",
        "worker_evidence": "included" if evidence else "not-checked",
        "counts": {"repos": len(repos), "ready": ready, "not_ready": len(repos) - ready},
        # A partial fleet or missing worker auth can never yield an all-ready receipt.
        "all_ready": bool(repos) and actor is not None and ready == len(repos),
        "repos": repos,
    }
    receipt["readiness_sha256"] = sha256_bytes(canonical_bytes(
        {key: value for key, value in receipt.items() if key != "checked_at"}
    ))
    return receipt


def repo_lines(item: dict[str, Any]) -> list[str]:
    """Readiness detail lines for one repository."""
    pad = f"  {'':<10}"
    lines = [f"  {'ready' if item['ready'] else 'NOT READY':<10} {item['slug']}"]
    lines += [f"{pad} {label}: {', '.join(values)}"
              for label, values in (("problems", item["problems"]), ("warnings", item["warnings"])) if values]
    if item.get("repair"):
        lines.append(f"{pad} repair: {item['repair']}")
    found = item.get("worker_evidence")
    if found:
        lines.append(f"{pad} worker evidence: {found['status']} {found.get('last_merged_worker_pr') or ''}".rstrip())
    return lines


def print_readiness(receipt: dict[str, Any], *, all_repos: bool) -> None:
    """Summary plus not-ready detail (every repo with --all); codes only, never remote payloads."""
    counts = receipt["counts"]
    print(f"Fleet owner: {receipt['owner']}  gh actor: {receipt['gh_actor'] or 'NOT AUTHENTICATED'}")
    print(f"Readiness (configured, not proof of worker runs): ready={counts['ready']} "
          f"not_ready={counts['not_ready']} of {counts['repos']}  all_ready={receipt['all_ready']}")
    tally: dict[str, int] = {}
    for item in receipt["repos"]:
        for warning in item["warnings"]:
            tally[warning] = tally.get(warning, 0) + 1
    if tally:
        print("Warnings: " + ", ".join(f"{name}={count}" for name, count in sorted(tally.items()))
              + ("" if all_repos else "  (--all lists every repository)"))
    for item in receipt["repos"]:
        if all_repos or not item["ready"]:
            print("\n".join(repo_lines(item)))
