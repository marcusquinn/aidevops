#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Repository GitHub authorization: profiles, explicit routes and local usage."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from github_app_auth import AuthError
from github_auth_config import entry_for, paths, registry, settings, update_registry
from github_auth_migration import migrate
from github_auth_policy import policy
from github_auth_profiles import manage_profile
from github_auth_routing import APP, decide, valid_slug
from github_auth_runtime import execute
from github_auth_usage import usage


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    actions = root.add_subparsers(dest="action", required=True)
    for name in ("set", "clear", "status", "check"):
        command = actions.add_parser(name)
        command.add_argument("repo")
        command.add_argument("--consumer", choices=("pulse",), required=name in ("set", "clear"))
        command.add_argument("--operation", choices=("read", "write"), required=name in ("set", "clear"))
        if name == "set":
            selection = command.add_mutually_exclusive_group(required=True)
            selection.add_argument("--inherit", action="store_true")
            selection.add_argument("--profile")
            command.add_argument("--installation-id")
    command = actions.add_parser("usage")
    command.add_argument("--since", default="1h")
    command.add_argument("--consumer", choices=("pulse",))
    command = actions.add_parser("migrate")
    command.add_argument("--confirm-stopped", action="store_true")
    profiles = actions.add_parser("profile").add_subparsers(dest="profile_action", required=True)
    profiles.add_parser("list")
    profiles.add_parser("show").add_argument("name")
    command = profiles.add_parser("set")
    command.add_argument("name")
    command.add_argument("--app-id", required=True)
    command.add_argument("--client-id")
    command.add_argument("--private-key-path", required=True)
    command.add_argument("--replace", action="store_true")
    return root


def describe(args, registry_path, config_path):
    data = registry(registry_path)
    entry = entry_for(data, args.repo)
    routes = policy(entry)
    result = {"repository": args.repo, "consumer": "pulse", "configured": routes is not None,
              "routes": routes, "interactive": "unchanged", "app_error_fallback": False,
              "coverage": "supported single-repository reads; unscoped calls retain inherited auth"}
    operations = [args.operation] if args.operation else ["read", "write"]
    for operation in operations:
        settings(data, args.repo, config_path, operation)
    if args.action == "check":
        if args.operation == "write":
            raise AuthError("Write checks are not supported; no remote changes are performed")
        if not routes or routes["read"]["provider"] != "github-app":
            raise AuthError("No App read route configured; inherited identity is not verified by this check")
        reason, _ = decide(["api", f"/repos/{args.repo}", "--silent"], data, config_path)
        if reason != APP:
            raise AuthError(f"Read check would inherit credentials ({reason}); refusing")
        rc = execute(str(Path(__file__).with_name("gh")),
                     ["api", f"/repos/{args.repo}", "--silent"], data, config_path)
        if rc:
            return rc
        result["read_check"] = "passed"
    print(json.dumps(result, indent=2))
    return 0


def main():
    args = parser().parse_args()
    registry_path, config_path = paths()
    if args.action == "profile":
        return manage_profile(args, config_path)
    if args.action == "migrate":
        return migrate(registry_path, config_path, args.confirm_stopped)
    if args.action == "usage":
        return usage(args.since, registry(registry_path), args.consumer)
    if not valid_slug(args.repo):
        raise AuthError("Repository must be owner/repo")
    if args.action == "set" and args.inherit and args.installation_id:
        raise AuthError("--installation-id cannot be combined with --inherit")
    if args.action in ("set", "clear"):
        return update_registry(args, registry_path, config_path)
    return describe(args, registry_path, config_path)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AuthError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, AuthError) else "GitHub authentication failed", file=sys.stderr)
        sys.exit(1)
