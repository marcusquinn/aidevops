# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bulk Pulse read binding for one GitHub App profile (GH#38337).

Discovers the App's installations, then binds the read route of every covered
pulse repository in one locked registry write. Write routes are preserved.
Repositories outside a selected installation are refused, because App read
failures never fall back to the personal token.
"""
from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess  # nosec B404 -- fixed sibling runtime check argv only, never a shell
import sys

from github_app_auth import AuthError, api, atomic_json, exchange, jwt
from github_auth_config import entry_for, load_profiles, registry, registry_lock, settings
from github_auth_policy import policy, validate_routes
from github_auth_routing import valid_slug

PAGE = 100


@dataclass(frozen=True)
class BindOptions:
    """One bind request; empty `owners` means every installation owner."""

    profile: str
    owners: tuple = ()
    dry_run: bool = False
    replace: bool = False
    check: bool = True

    @property
    def wanted(self):
        return {owner.lower() for owner in self.owners}


def installations(profile):
    credential = jwt(profile)
    result, page = [], 1
    while True:
        batch = api("GET", f"/app/installations?per_page={PAGE}&page={page}", credential)
        if not isinstance(batch, list):
            raise AuthError("Unexpected installations response")
        result.extend(item for item in batch if isinstance(item, dict) and isinstance(item.get("account"), dict))
        if len(batch) < PAGE:
            return result
        page += 1


def coverage(profile, installation):
    """Return lower-case covered full names, or None when every repository is covered."""
    if installation.get("repository_selection") == "all":
        return None
    token = exchange(profile, installation["id"])["token"]
    names, page = set(), 1
    while True:
        data = api("GET", f"/installation/repositories?per_page={PAGE}&page={page}", token)
        repos = data.get("repositories") if isinstance(data, dict) else None
        if not isinstance(repos, list):
            raise AuthError("Unexpected installation repositories response")
        names.update(str(repo.get("full_name", "")).lower() for repo in repos if isinstance(repo, dict))
        if len(repos) < PAGE:
            return names
        page += 1


def installation_index(profile, owners=()):
    wanted = {owner.lower() for owner in owners}
    index = {}
    for item in installations(profile):
        login = str(item["account"].get("login", "")).lower()
        if wanted and login not in wanted:
            continue
        suspended = bool(item.get("suspended_at"))
        index[login] = {"id": str(item["id"]), "suspended": suspended,
                        "covered": None if suspended else coverage(profile, item)}
    return index


def _skip_reason(entry, install, slug):
    """Return the first registry or installation reason that forbids binding."""
    covered = install["covered"] if install else None
    rules = (
        (not entry.get("pulse"), "not-pulse-enabled"),
        (bool(entry.get("local_only")), "local-only"),
        ("pulse_auth" in entry, "legacy-binding-run-migrate"),
        (install is None, "no-installation"),
        (bool(install and install["suspended"]), "installation-suspended"),
        (covered is not None and slug.lower() not in covered, "not-in-selected-installation"),
    )
    return next((reason for blocked, reason in rules if blocked), None)


def _route_conflict(entry, route, replace):
    """Return why the existing read route must be kept, or None to bind."""
    try:
        current = policy(entry)
    except AuthError:
        return "invalid-existing-policy"
    read = (current or {}).get("read") or {}
    if read == route:
        return "already-bound"
    if read.get("provider") == "github-app" and not replace:
        return "bound-to-other-app"
    return None


def decide_entry(entry, index, options):
    """Return (reason, route); route is set only when the entry should be bound."""
    slug = str(entry.get("slug") or "")
    install = index.get(slug.split("/")[0].lower())
    reason = _skip_reason(entry, install, slug)
    if reason is None:
        route = {"provider": "github-app", "profile": options.profile, "installation_id": install["id"]}
        reason = _route_conflict(entry, route, options.replace)
        if reason is None:
            return "bind", route
    return reason, None


def plan(data, index, options):
    wanted = options.wanted
    decisions = []
    for entry in data["initialized_repos"]:
        slug = str(entry.get("slug") or "")
        if "/" not in slug or (wanted and slug.split("/")[0].lower() not in wanted):
            continue
        reason, route = decide_entry(entry, index, options)
        decisions.append({"repo": slug, "decision": reason, "route": route})
    return decisions


def _apply(registry_path, config_path, index, options):
    with registry_lock(registry_path):
        data = registry(registry_path)
        decisions = plan(data, index, options)
        binds = [item for item in decisions if item["decision"] == "bind"]
        for item in binds:
            entry = entry_for(data, item["repo"])
            current = policy(entry) or {"write": {"provider": "inherit"}}
            routes = {"read": item["route"], "write": current["write"]}
            validate_routes(routes)
            entry.setdefault("github_auth", {})["pulse"] = routes
            settings(data, item["repo"], config_path)
        if binds:
            atomic_json(registry_path, data)
    return decisions


def _check(repo):
    """Run the full Pulse runtime check: installation grants, minted-token
    permissions and a live App read. A metadata-only read is not enough,
    because App read failures never fall back to the personal token."""
    if not valid_slug(repo):
        return "failed"
    runtime = Path(__file__).with_name("github_auth_runtime.py")
    # Fixed sibling script and a validated owner/repo slug; argv list, no shell.
    result = subprocess.run([sys.executable, str(runtime), "check", repo],  # nosec B603 nosemgrep
                            capture_output=True, text=True, timeout=120, check=False)
    return "passed" if result.returncode == 0 and '"read_check": "passed"' in result.stdout else "failed"


def _read_checks(decisions):
    """Run one live read check per owner on its first bound repository."""
    first = {}
    for item in decisions:
        if item["decision"] in ("bind", "already-bound"):
            first.setdefault(item["repo"].split("/")[0].lower(), item["repo"])
    return {repo: _check(repo) for repo in first.values()}


def bind_app(options, registry_path, config_path):
    profile = load_profiles(config_path)["profiles"].get(options.profile)
    if not isinstance(profile, dict):
        raise AuthError("Unknown GitHub auth profile")
    index = installation_index(profile, options.owners)
    if options.dry_run:
        decisions = plan(registry(registry_path), index, options)
    else:
        decisions = _apply(registry_path, config_path, index, options)
    result = {"profile": options.profile, "dry_run": options.dry_run, "installations": sorted(index),
              "counts": dict(Counter(item["decision"] for item in decisions)),
              "repositories": [{"repo": i["repo"], "decision": i["decision"]} for i in decisions
                               if i["decision"] != "not-pulse-enabled"]}
    if options.check and not options.dry_run:
        result["read_checks"] = _read_checks(decisions)
    print(json.dumps(result, indent=2))
    failed = [repo for repo, state in result.get("read_checks", {}).items() if state != "passed"]
    return 1 if failed else 0
