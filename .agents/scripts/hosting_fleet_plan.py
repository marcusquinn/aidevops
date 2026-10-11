#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify fleet sites against repos.json and the canonical owner layout.

Read-only: inspects registrations, destination paths and origin remotes, and
returns a content-hashed plan. Owner paths come from the shared
repo-discovery-lib.sh policy (personal owners -> <git-root>/<repo>).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_inventory import DOMAIN_RE, FleetError  # noqa: E402
from repo_layout_migrate import (  # noqa: E402
    MigrationError,
    canonical_bytes,
    expand_path,
    load_json,
    parse_remote,
    recommended_path,
    run,
    sha256_bytes,
)

PLAN_SCHEMA = "aidevops-hostinger-fleet-plan/v1"
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
# Site states that need no action; every other state is drift.
CLEAN_STATES = frozenset({"ok", "ok-exception"})
STATE_ACTIONS = {
    "ok": ("none", None),
    "ok-exception": ("none", None),
    "new": ("provision", None),
    "unregistered-clone": ("register", None),
    "missing-clone": ("clone", None),
    "misplaced": ("migrate-layout", None),
    "ambiguous": ("review", "Multiple registrations share this repository name"),
    "collision": ("review", "Destination exists with a different or missing origin"),
    "owner-mismatch": ("review", "Registered owner differs; pass DOMAIN=OWNER if intentional"),
    "not-in-hosting": ("review", "Registered but not hosted; retire or --ignore it"),
}


def parse_exceptions(values: list[str] | None) -> dict[str, str]:
    """Parse DOMAIN=OWNER owner exceptions."""
    exceptions = {}
    for value in values or []:
        domain, separator, owner = value.partition("=")
        domain = domain.strip().lower()
        owner = owner.strip()
        if not separator or not DOMAIN_RE.match(domain) or not OWNER_RE.match(owner):
            raise FleetError("Owner exceptions must use DOMAIN=OWNER")
        exceptions[domain] = owner
    return exceptions


def parse_site_repos(values: list[str] | None) -> dict[str, str]:
    """Parse HOSTED_DOMAIN=REPO maps: a hosted site served by a differently named repo.

    Used for pre-launch hosts (a staging subdomain whose production domain names
    the repository) and network blogs that share a repository.
    """
    site_repos = {}
    for value in values or []:
        domain, separator, repo = value.partition("=")
        domain = domain.strip().lower()
        repo = repo.strip().lower()
        if not separator or not DOMAIN_RE.match(domain) or not DOMAIN_RE.match(repo):
            raise FleetError("Site repositories must use HOSTED_DOMAIN=REPO_DOMAIN")
        site_repos[domain] = repo
    return site_repos


def load_registrations(repos_json: Path) -> list[dict[str, str]]:
    """Return initialized repository registrations with owner, name and path."""
    payload = load_json(repos_json)
    records = payload.get("initialized_repos", []) if isinstance(payload, dict) else []
    registrations = []
    for item in records:
        slug = str(item.get("slug") or "")
        owner, separator, name = slug.partition("/")
        if separator and name:
            registrations.append(
                {"slug": slug, "owner": owner, "name": name, "path": str(item.get("path") or "")}
            )
    return registrations


def origin_matches(path: Path, owner: str, name: str) -> bool:
    """True when an existing clone's origin is exactly owner/name."""
    if not (path / ".git").is_dir():
        return False
    try:
        identity = parse_remote(run(["git", "-C", str(path), "remote", "get-url", "origin"]))
    except MigrationError:
        return False
    return bool(identity) and identity[1].lower() == owner.lower() and identity[2].lower() == name


def unregistered_state(destination: Path, owner: str, domain: str) -> str:
    """State for a site with no registration."""
    if not destination.exists():
        return "new"
    return "unregistered-clone" if origin_matches(destination, owner, domain) else "collision"


def registered_state(registration: dict[str, str], destination: Path, owner: str) -> str:
    """State for a site with exactly one registration (exceptions resolved by caller)."""
    path = expand_path(registration["path"]) if registration["path"] else None
    if registration["owner"].lower() != owner.lower():
        state = "owner-mismatch"
    elif path is None or not (path / ".git").exists():
        state = "missing-clone"
    elif path != destination:
        state = "misplaced"
    else:
        state = "ok"
    return state


def plan_entry(domain: str, state: str, **fields: Any) -> dict[str, Any]:
    """Uniform plan record with the action and detail implied by its state."""
    action, detail = STATE_ACTIONS[state]
    entry = {
        "domain": domain,
        "role": None,
        "codebase_primary": None,
        "expected_slug": None,
        "expected_path": None,
        "registered_slug": None,
        "registered_path": None,
        **fields,
        "state": state,
        "action": action,
    }
    if detail:
        entry["detail"] = detail
    return entry


def classify_site(site: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Classify one site against registrations and the canonical layout."""
    domain = site["domain"]
    repo = context["site_repos"].get(domain, domain)
    owner = context["exceptions"].get(repo, context["exceptions"].get(domain, context["owner"]))
    destination = recommended_path(
        context["workspace"], (context["host"], owner, repo), context["repos_json"], context["lib"]
    )
    matches = [item for item in context["registrations"] if item["name"].lower() == repo]
    registration = matches[0] if len(matches) == 1 else {}
    if len(matches) > 1:
        state = "ambiguous"
    elif registration:
        state = registered_state(registration, destination, owner)
    else:
        state = unregistered_state(destination, owner, repo)
    if state == "ok" and (domain in context["exceptions"] or repo != domain
                          or repo in context["exceptions"]):
        state = "ok-exception"
    entry = plan_entry(
        domain,
        state,
        role=site.get("role"),
        codebase_primary=site.get("codebase_primary"),
        expected_slug=f"{owner}/{repo}",
        expected_path=str(destination),
        registered_slug=registration.get("slug"),
        registered_path=registration.get("path"),
    )
    if repo != domain:
        entry["served_by"] = repo
    return entry


def not_in_hosting(context: dict[str, Any], hosted: set[str]) -> list[dict[str, Any]]:
    """Fleet-owner registrations named for a domain that is no longer hosted."""
    owner = context["owner"].lower()
    results = [
        plan_entry(
            item["name"].lower(),
            "not-in-hosting",
            registered_slug=item["slug"],
            registered_path=item["path"],
        )
        for item in context["registrations"]
        if item["owner"].lower() == owner
        and DOMAIN_RE.match(item["name"].lower())
        and item["name"].lower() not in hosted | context["ignored"]
    ]
    return sorted(results, key=lambda entry: entry["domain"])


def mark_shared_destinations(results: list[dict[str, Any]]) -> None:
    """Two sites must never plan the same destination unless a site-repo map joins them."""
    seen: dict[str, dict[str, Any]] = {}
    for item in results:
        path = item.get("expected_path")
        if not path:
            continue
        first = seen.setdefault(path, item)
        if first is item or first.get("expected_slug") == item.get("expected_slug") and (
            item.get("served_by") or first.get("served_by")
        ):
            continue
        item.update(state="collision", action=STATE_ACTIONS["collision"][0],
                    detail=f"Shares a destination with {first['domain']}")


def plan_context(options: dict[str, Any]) -> dict[str, Any]:
    """Validate operator options and load registrations."""
    if not OWNER_RE.match(options["owner"]):
        raise FleetError("Owner must be a GitHub account or organization name")
    repos_json = expand_path(options["repos_json"])
    return {
        "owner": options["owner"],
        "host": options["host"],
        "exceptions": parse_exceptions(options.get("owner_exception")),
        "site_repos": parse_site_repos(options.get("site_repo")),
        "ignored": {value.strip().lower() for value in options.get("ignore") or []},
        "workspace": expand_path(options["workspace"]),
        "repos_json": repos_json,
        "lib": expand_path(options["discovery_lib"]),
        "registrations": load_registrations(repos_json),
    }


def build_plan(inventory: dict[str, Any], options: dict[str, Any]) -> dict[str, Any]:
    """Classify every site without mutating anything."""
    context = plan_context(options)
    hosted = {site["domain"] for site in inventory["sites"]}
    hosted |= {context["site_repos"].get(domain, domain) for domain in hosted}
    results = [
        classify_site(site, context)
        for site in inventory["sites"]
        if site["domain"] not in context["ignored"]
    ]
    results.extend(not_in_hosting(context, hosted))
    mark_shared_destinations(results)
    counts: dict[str, int] = {}
    for item in results:
        counts[item["state"]] = counts.get(item["state"], 0) + 1
    plan = {
        "schema": PLAN_SCHEMA,
        "inventory_sha256": inventory.get("inventory_sha256"),
        "owner": context["owner"],
        "host": context["host"],
        "owner_exceptions": context["exceptions"],
        "site_repos": context["site_repos"],
        "ignored": sorted(context["ignored"]),
        "workspace": str(context["workspace"]),
        "counts": dict(sorted(counts.items())),
        "drift": sum(count for state, count in counts.items() if state not in CLEAN_STATES),
        "sites": results,
    }
    plan["plan_sha256"] = sha256_bytes(canonical_bytes(plan))
    return plan
