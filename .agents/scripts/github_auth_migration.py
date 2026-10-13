# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Explicit, idempotent migration; never invoked on a GitHub request path."""
import json
import os
from pathlib import Path

from github_app_auth import AuthError, atomic_json, private_read
from github_auth_config import load_profiles, registry, registry_lock, settings
from github_auth_policy import policy


def profile_destination():
    override = os.environ.get("AIDEVOPS_GITHUB_AUTH_CONFIG") or os.environ.get("AIDEVOPS_GITHUB_APP_CONFIG")
    return Path(override) if override else Path.home() / ".config/aidevops/github-auth.json"


def check_profile_conflicts(data, config_path):
    # Normal reads prefer the canonical file. Migration must also inspect the
    # old default so that a name collision cannot silently change identity.
    if os.environ.get("AIDEVOPS_GITHUB_AUTH_CONFIG") or os.environ.get("AIDEVOPS_GITHUB_APP_CONFIG"):
        return
    legacy_path = config_path.with_name("github-app-auth.json")
    if legacy_path == config_path or not legacy_path.exists():
        return
    legacy = load_profiles(legacy_path)["profiles"]
    current = load_profiles(config_path)["profiles"]
    for entry in data["initialized_repos"]:
        if "pulse_auth" in entry:
            route = policy(entry)["read"]
            name = route["profile"]
            if name not in legacy or legacy[name] != current.get(name):
                raise AuthError("Conflicting profile files for a legacy binding; reconcile them explicitly")


def migrate(registry_path, config_path, confirmed):
    if not confirmed:
        raise AuthError("Stop old Pulse processes and config writers, then use migrate --confirm-stopped")
    with registry_lock(registry_path):
        data = registry(registry_path)
        check_profile_conflicts(data, config_path)
        changed = 0
        # Validate every entry before changing either file. Duplicate App entries fail.
        for entry in data["initialized_repos"]:
            routes = policy(entry)
            if routes:
                settings(data, entry.get("slug", ""), config_path)
            if "pulse_auth" in entry:
                entry.setdefault("github_auth", {})["pulse"] = routes
                del entry["pulse_auth"]
                changed += 1
        destination = profile_destination()
        if destination != config_path and config_path.exists():
            with registry_lock(destination):
                profiles = json.loads(private_read(config_path))
                if destination.exists():
                    if json.loads(private_read(destination)) != profiles:
                        raise AuthError("Conflicting profile files; reconcile them explicitly")
                else:
                    atomic_json(destination, profiles)
        if changed:
            atomic_json(registry_path, data)
    print(json.dumps({"migrated_repositories": changed, "profiles_path": str(destination),
                      "pulse_enabled_changed": False, "legacy_profile_file_retained": destination != config_path}))
    return 0
