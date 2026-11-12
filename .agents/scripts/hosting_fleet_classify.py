#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Per-site state classification for the hosting fleet plan.

Read-only: compares one hosted site with repos.json registrations, the
canonical destination path and the clone's origin remote.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_inventory import FleetError  # noqa: E402
from hosting_fleet_checks import gh_json  # noqa: E402
from repo_layout_migrate import (  # noqa: E402
    MigrationError,
    expand_path,
    parse_remote,
    recommended_path,
    run,
)

STATE_ACTIONS = {
    "ok": ("none", None),
    "ok-exception": ("none", None),
    "new": ("provision", None),
    "unregistered-clone": ("register", None),
    "missing-clone": ("clone", None),
    "misplaced": ("migrate-layout", None),
    "transferred": ("follow-transfer-and-migrate-layout", None),
    "ambiguous": ("review", "Multiple registrations share this repository name"),
    "collision": ("review", "Destination exists with a different or missing origin"),
    "owner-mismatch": ("review", "Registered owner differs; pass DOMAIN=OWNER if intentional"),
    "not-in-hosting": ("review", "Registered but not hosted; retire or --ignore it"),
}


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


def transfer_matches(old_slug: str, target: str) -> bool:
    """Resolve both slugs and require a matching immutable repository ID."""
    old, old_error = gh_json(f"repos/{old_slug}")
    new, new_error = gh_json(f"repos/{target}")
    if "failed" in (old_error, new_error):
        # A transient lookup failure is uncertain identity, not a verified non-match.
        raise FleetError(f"Cannot verify repository transfer {old_slug} -> {target}; refusing provisioning")
    if old_error or new_error:
        return False
    old_id = (old or {}).get("id")
    new_name = str((new or {}).get("full_name") or "").lower()
    return old_id is not None and old_id == (new or {}).get("id") and new_name == target.lower()


def site_registrations(domain: str, repo: str, owner: str, context: dict[str, Any]) -> list[dict[str, str]]:
    """Find registrations, refusing uncertain renamed-site identity."""
    registrations = context["registrations"]
    matches = [item for item in registrations if item["name"].lower() == repo]
    # A renamed site may still be registered under its hosted domain; never
    # infer identity from a redirect alone.
    candidates = [item for item in registrations if item["name"].lower() == domain]
    if matches:
        return matches
    target = f"{owner}/{repo}"
    if repo != domain and candidates:
        if len(candidates) == 1 and not transfer_matches(candidates[0]["slug"], target):
            raise FleetError(f"Cannot verify repository transfer for {domain}; refusing provisioning")
        return candidates
    # A previous domain can differ from both the hosted domain and mapped name.
    # Search only this fleet's owners, and never infer a rename from names alone.
    owners = {context["owner"].lower(), owner.lower()}
    return [item for item in registrations if item["owner"].lower() in owners
            and transfer_matches(item["slug"], target)]


def site_state(matches: list[dict[str, str]], destination: Path, owner: str, repo: str) -> str:
    """Select a state after registration matching."""
    if len(matches) > 1:
        return "ambiguous"
    if not matches:
        return unregistered_state(destination, owner, repo)
    registration = matches[0]
    target = f"{owner}/{repo}"
    if registration["name"].lower() != repo:
        return "transferred"
    if registration["slug"].lower() == target.lower():
        return registered_state(registration, destination, owner)
    return "transferred" if transfer_matches(registration["slug"], target) else "owner-mismatch"


def classify_site(site: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    """Classify one site against registrations and the canonical layout."""
    domain = site["domain"]
    repo = context["site_repos"].get(domain, domain)
    owner = context["exceptions"].get(repo, context["exceptions"].get(domain, context["owner"]))
    destination = recommended_path(
        context["workspace"], (context["host"], owner, repo), context["repos_json"], context["lib"]
    )
    matches = site_registrations(domain, repo, owner, context)
    registration = matches[0] if len(matches) == 1 else {}
    state = site_state(matches, destination, owner, repo)
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
