# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Manage App profile metadata without displaying keys or tokens."""
import json
import os
from pathlib import Path
import re

from github_app_auth import AuthError, atomic_json, private_read
from github_auth_config import load_profiles, registry_lock
from github_auth_migration import profile_destination


def manage_profile(args, config_path):
    data = load_profiles(config_path)
    if args.profile_action == "list":
        print(json.dumps({"profiles": sorted(data["profiles"])}))
        return 0
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.name):
        raise AuthError("Profile name must contain only letters, numbers, dots, underscores or hyphens")
    if args.profile_action == "show":
        profile = data["profiles"].get(args.name)
        if not isinstance(profile, dict):
            raise AuthError("Unknown GitHub auth profile")
        public = {key: profile[key] for key in ("app_id", "client_id", "private_key_path", "permissions") if key in profile}
        print(json.dumps({"profile": args.name, **public}, indent=2))
        return 0
    if not args.app_id.isdigit():
        raise AuthError("App ID must be numeric")
    key = Path(os.path.expandvars(args.private_key_path)).expanduser().absolute()
    private_read(key, secret=True)
    destination = profile_destination()
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with registry_lock(destination):
        # Preserve legacy profiles when creating the canonical file for the first time.
        data = load_profiles(destination if destination.exists() else config_path)
        profile = {"app_id": args.app_id, "private_key_path": str(key),
                   "permissions": {"metadata": "read", "issues": "read", "pull_requests": "read"}}
        previous = data["profiles"].get(args.name, {})
        if not isinstance(previous, dict):
            raise AuthError("Invalid existing GitHub auth profile")
        permissions = previous.get("permissions", profile["permissions"])
        if not isinstance(permissions, dict) or not permissions or any(v != "read" for v in permissions.values()):
            raise AuthError("Profile replacement requires read-only permissions")
        profile["permissions"] = permissions
        if args.client_id:
            profile["client_id"] = args.client_id
        if args.name in data["profiles"] and not args.replace:
            raise AuthError("Profile exists; use --replace explicitly to rotate or change it")
        data["profiles"][args.name] = profile
        atomic_json(destination, data)
    print(json.dumps({"profile": args.name, "updated": True, "profiles_path": str(destination)}))
    return 0
