# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Repository registry and read-only GitHub App profile configuration."""

import contextlib
import json
import os
from pathlib import Path
import time

from github_app_auth import AuthError, atomic_json, private_read
from github_auth_policy import policy, validate_routes


def paths():
    base = Path.home() / ".config/aidevops"
    configured = os.environ.get("AIDEVOPS_GITHUB_AUTH_CONFIG") or os.environ.get("AIDEVOPS_GITHUB_APP_CONFIG")
    profile_path = Path(configured) if configured else base / "github-auth.json"
    if not configured and not profile_path.exists() and not profile_path.is_symlink():
        profile_path = base / "github-app-auth.json"
    return (Path(os.environ.get("AIDEVOPS_REPOS_CONFIG", base / "repos.json")),
            profile_path)


def registry(path):
    if not path.exists() and not path.is_symlink():
        return {"initialized_repos": []}
    value = json.loads(private_read(path))
    if (not isinstance(value, dict) or not isinstance(value.get("initialized_repos"), list)
            or not all(isinstance(entry, dict) for entry in value["initialized_repos"])):
        raise AuthError("Invalid repository registry")
    return value


def matching_entries(data, repo):
    return [entry for entry in data["initialized_repos"] if str(entry.get("slug", "")).lower() == repo.lower()]


def entry_for(data, repo):
    entries = matching_entries(data, repo)
    if len(entries) != 1:
        raise AuthError("Repository must have exactly one registry entry")
    return entries[0]


def any_configured(data):
    return any(policy(entry) is not None for entry in data["initialized_repos"])


def load_profiles(path):
    if not path.exists() and not path.is_symlink():
        return {"profiles": {}}
    data = json.loads(private_read(path))
    if not isinstance(data, dict) or not isinstance(data.get("profiles"), dict):
        raise AuthError("Invalid GitHub auth profiles file")
    return data


def settings(data, repo, config_path, operation="read"):
    # Unregistered repositories and entries without pulse_auth keep their
    # existing auth. Only an App selection must be unambiguous and valid.
    entries = matching_entries(data, repo)
    if all(policy(entry) is None for entry in entries):
        return None
    entry = entry_for(data, repo)
    routes = policy(entry)
    validate_routes(routes)
    auth = routes[operation]
    if auth["provider"] == "inherit":
        return None
    if entry.get("local_only"):
        raise AuthError("Local-only repositories cannot use GitHub App auth")
    config = load_profiles(config_path)
    profile = config["profiles"].get(auth.get("profile"))
    if not isinstance(profile, dict) or not str(profile.get("app_id", "")).isdigit():
        raise AuthError("Missing or invalid GitHub App profile")
    if not profile.get("private_key_path") or not str(auth.get("installation_id", "")).isdigit():
        raise AuthError("Missing key path or installation ID")
    permissions = profile.get("permissions", {"metadata": "read", "issues": "read", "pull_requests": "read"})
    if not isinstance(permissions, dict) or not permissions or any(v != "read" for v in permissions.values()):
        raise AuthError("Pulse App profile must request only read permissions")
    return auth, profile


@contextlib.contextmanager
def registry_lock(path):
    # Share the mkdir lock used by aidevops_with_registry_lock, not a second lock.
    directory = Path(str(path) + ".lock")
    deadline = time.monotonic() + 10
    while True:
        try:
            directory.mkdir(mode=0o700)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise AuthError("Repository registry is locked") from None
            time.sleep(0.1)
    try:
        yield
    finally:
        directory.rmdir()


def update_registry(args, registry_path, config_path):
    with registry_lock(registry_path):
        data = registry(registry_path)
        entry = entry_for(data, args.repo)
        if "pulse_auth" in entry:
            raise AuthError("Legacy binding: stop old Pulse processes and run github auth migrate --confirm-stopped first")
        routes = policy(entry) or {"read": {"provider": "inherit"}, "write": {"provider": "inherit"}}
        if args.action == "set":
            routes[args.operation] = ({"provider": "inherit"} if args.inherit else
                                      {"provider": "github-app", "profile": args.profile,
                                       "installation_id": args.installation_id})
        else:
            routes[args.operation] = {"provider": "inherit"}
        validate_routes(routes)
        entry.setdefault("github_auth", {})[args.consumer] = routes
        entry.pop("pulse_auth", None)
        settings(data, args.repo, config_path)
        atomic_json(registry_path, data)
    print(json.dumps({"updated": True, "pulse_enabled_changed": False}))
    return 0
