#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify fleet sites against repos.json and the canonical owner layout.

Read-only: inspects registrations, destination paths and origin remotes, and
returns a content-hashed plan. Owner paths come from the shared
repo-discovery-lib.sh policy (personal owners -> <git-root>/<repo>).
Per-site classification lives in hosting_fleet_classify.py.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_classify import (  # noqa: E402,F401
    STATE_ACTIONS,
    classify_site,
    plan_entry,
)
from hosting_fleet_inventory import DOMAIN_RE, FleetError  # noqa: E402
from repo_layout_migrate import canonical_bytes, expand_path, load_json, sha256_bytes  # noqa: E402

PLAN_SCHEMA = "aidevops-hostinger-fleet-plan/v1"
OWNER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
# Site states that need no action; every other state is drift.
CLEAN_STATES = frozenset({"ok", "ok-exception"})


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
    hosted |= {item["registered_slug"].split("/", 1)[1].lower() for item in results
               if item["state"] == "transferred" and item.get("registered_slug")}
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
