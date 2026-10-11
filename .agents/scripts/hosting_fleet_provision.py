#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resumable fleet provisioning from a reviewed, content-hashed plan.

Selects plan repositories in a provisionable state and runs ordered steps:

  new                 remote -> clone -> init -> deliver
  unregistered-clone  init -> deliver
  missing-clone       clone

Without --apply this is a read-only preview. --apply requires the exact
plan_sha256 of the saved plan, so execution is bound to the plan the operator
reviewed, and refuses plans older than 24 hours or contradicted by the current
fleet config (owner change, newly ignored sites). Steps re-check live state, so a repeat run resumes and adopts work
already done. Every step result is appended to an owner-private JSONL receipt;
a partial run is reported per repository and never summarised as complete.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_checks import gh_json  # noqa: E402
from hosting_fleet_deliver import deliver_step  # noqa: E402
from hosting_fleet_inventory import FleetError  # noqa: E402
from hosting_fleet_plan import parse_exceptions, parse_site_repos  # noqa: E402
from hosting_fleet_privacy import config_pairs  # noqa: E402
from hosting_fleet_steps import clone_step, init_step, remote_step  # noqa: E402
from repo_layout_migrate import canonical_bytes, expand_path, load_json, private_directory, sha256_bytes  # noqa: E402

PROVISION_SCHEMA = "aidevops-hostinger-fleet-provision/v1"
STEPS_BY_STATE = {
    "new": ("remote", "clone", "init", "deliver"),
    "unregistered-clone": ("init", "deliver"),
    "missing-clone": ("clone",),
}
STOP_STATUSES = {"failed", "pending"}
MAX_PLAN_AGE_SECONDS = 24 * 3600


def load_reviewed_plan(path: Path, expected_sha: str | None) -> dict[str, Any]:
    """Load a saved plan whose content hash is intact and, if given, matches."""
    plan = load_json(path)
    if not isinstance(plan, dict) or "plan_sha256" not in plan:
        raise FleetError("Plan file is not a fleet plan")
    body = {key: value for key, value in plan.items() if key != "plan_sha256"}
    if sha256_bytes(canonical_bytes(body)) != plan["plan_sha256"]:
        raise FleetError("Plan content does not match its plan_sha256; re-run fleet plan")
    if expected_sha is not None and expected_sha != plan["plan_sha256"]:
        raise FleetError("--plan-sha256 does not match the saved plan; review the current plan first")
    return plan


def config_drift(plan: dict[str, Any], config: dict[str, Any]) -> list[str]:
    """Current fleet config entries the plan does not reflect (names only, no values)."""
    reasons = []
    owner = config.get("owner")
    if owner and str(owner).lower() != str(plan.get("owner") or "").lower():
        reasons.append("owner")
    planned_ignores = {str(item).lower() for item in plan.get("ignored") or []}
    if {str(item).strip().lower() for item in config.get("ignore") or []} - planned_ignores:
        reasons.append("ignore")
    for key, plan_key, parse in (("site_repos", "site_repos", parse_site_repos),
                                 ("owner_exceptions", "owner_exceptions", parse_exceptions)):
        planned = plan.get(plan_key) or {}
        if any(planned.get(name) != value for name, value in parse(config_pairs(config, key)).items()):
            reasons.append(key)
    return reasons


def assert_plan_current(path: Path, plan: dict[str, Any], config: dict[str, Any]) -> None:
    """Refuse to apply a stale plan or one the current fleet config contradicts."""
    age = datetime.now(timezone.utc).timestamp() - path.stat().st_mtime
    if age > MAX_PLAN_AGE_SECONDS:
        raise FleetError("Plan is older than 24 hours; re-run fleet plan and review it")
    reasons = config_drift(plan, config)
    if reasons:
        raise FleetError(f"Fleet config changed since this plan ({', '.join(reasons)}); re-run fleet plan")


def select_repos(plan: dict[str, Any], sites: list[str] | None) -> list[dict[str, Any]]:
    """Provisionable repositories (one per slug), optionally limited to named sites."""
    wanted = {site.strip().lower() for site in sites or []}
    groups: dict[str, dict[str, Any]] = {}
    for item in plan["sites"]:
        if item["state"] not in STEPS_BY_STATE or (wanted and item["domain"] not in wanted):
            continue
        group = groups.setdefault(item["expected_slug"], {
            "slug": item["expected_slug"], "path": item["expected_path"], "domains": [], "states": set()})
        group["domains"].append(item["domain"])
        group["states"].add(item["state"])
        registered = item.get("registered_path")
        if registered and expand_path(registered) != expand_path(item["expected_path"]):
            group["states"].add("registered-elsewhere")
    missing = wanted - {domain for group in groups.values() for domain in group["domains"]}
    if missing:
        raise FleetError(f"Not provisionable in this plan: {', '.join(sorted(missing))}")
    return sorted(groups.values(), key=lambda group: group["slug"])


def append_receipt(path: Path, record: dict[str, Any]) -> None:
    """Append one JSON line to the owner-private receipt."""
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def run_step(name: str, subject: dict[str, Any], context: dict[str, Any]) -> tuple[str, str]:
    """Dispatch one named step for one repository."""
    slug, destination, apply = subject["slug"], expand_path(subject["path"]), context["apply"]
    if name == "remote":
        return remote_step(slug, context["workspace"], apply)
    if name == "clone":
        return clone_step(slug, destination, apply)
    if name == "init":
        return init_step(slug, destination, context["repos_json"], apply)
    repo, _ = gh_json(f"repos/{slug}")
    branch = repo.get("default_branch") if isinstance(repo, dict) else None
    return deliver_step(slug, destination, branch, apply) if branch else ("failed", "default branch unknown")


def provision_repo(subject: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Run a repository's steps in order, stopping at failure or a pending PR."""
    result: dict[str, Any] = {"slug": subject["slug"], "domains": sorted(subject["domains"]), "steps": []}
    if "registered-elsewhere" in subject["states"]:
        result.update(status="failed", detail="registered at a non-canonical path; use the layout move first")
        return result
    if len(subject["states"]) != 1:
        result.update(status="failed", detail="hosts sharing this repository have different states; re-plan")
        return result
    waiting = False
    for name in STEPS_BY_STATE[next(iter(subject["states"]))]:
        # In a preview, later steps depend on state that earlier planned steps would create.
        status, detail = ("planned", "after the previous step") if waiting else run_step(name, subject, context)
        result["steps"].append({"step": name, "status": status, "detail": detail})
        if context["apply"]:
            append_receipt(context["receipt"], {"at": context["now"](), "slug": subject["slug"],
                                                "step": name, "status": status, "detail": detail})
        waiting = waiting or status == "planned"
        if status in STOP_STATUSES:
            break
    statuses = {step["status"] for step in result["steps"]}
    result["status"] = next((value for value in ("failed", "pending", "planned") if value in statuses), "complete")
    return result


def build_provision(plan: dict[str, Any], options: dict[str, Any]) -> dict[str, Any]:
    """Preview or apply provisioning and return the per-repository report."""
    state_dir = expand_path(options["state_dir"])
    if options["apply"]:
        private_directory(state_dir)
    mode = "apply" if options["apply"] else "preview"
    receipt = state_dir / f"provision-{plan['plan_sha256'][:16]}.jsonl"
    context = {
        "apply": options["apply"], "mode": mode, "receipt": receipt,
        "workspace": expand_path(plan["workspace"]), "repos_json": expand_path(options["repos_json"]),
        "now": lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    repos = [provision_repo(subject, context) for subject in select_repos(plan, options.get("site"))]
    counts: dict[str, int] = {}
    for item in repos:
        counts[item["status"]] = counts.get(item["status"], 0) + 1
    return {"schema": PROVISION_SCHEMA, "mode": mode, "plan_sha256": plan["plan_sha256"],
            "receipt": str(receipt), "counts": dict(sorted(counts.items())), "repos": repos}


def print_provision(report: dict[str, Any]) -> None:
    """Human summary: one line per step, never remote payloads."""
    counts = " ".join(f"{key}={value}" for key, value in report["counts"].items()) or "none"
    print(f"Provision {report['mode']}: plan_sha256 {report['plan_sha256']}  {counts}")
    for item in report["repos"]:
        print(f"  {item['status']:<9} {item['slug']}")
        if item.get("detail"):
            print(f"  {'':<9}   {item['detail']}")
        for step in item["steps"]:
            print(f"  {'':<9}   {step['step']:<8} {step['status']:<8} {step['detail']}")
    if report["mode"] == "apply":
        print(f"Receipt: {report['receipt']}")
    elif report["repos"]:
        print("Preview only (nothing written). Apply with: fleet provision --apply --plan-sha256 "
              + report["plan_sha256"])
