#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Repository-scoped Pulse read authentication; writes retain their original auth."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from github_app_auth import AuthError, cached_token
from pulse_auth_config import paths, registry, settings, update_registry
from pulse_gh_policy import api_endpoint, operation, option_values

SLUG = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def valid_slug(value):
    return bool(SLUG.fullmatch(value)) and all(part not in (".", "..") for part in value.split("/"))


def repository(args):
    candidates = option_values(args, "--repo", "-R")
    context = os.environ.get("AIDEVOPS_PULSE_REPO")
    if context:
        candidates.append(context)
    if len(args) > 1 and args[0] == "api":
        match = re.match(r"/?repos/([^/?#]+/[^/?#]+)(?:[/?#]|$)", api_endpoint(args))
        if match:
            candidates.append(match[1])
        fields = option_values(args, "--field", "-F") + option_values(args, "--raw-field", "-f")
        owners = [value[6:] for value in fields if value.startswith("owner=")]
        names = [value[5:] for value in fields if value.startswith("name=")]
        if api_endpoint(args).strip("/") == "graphql" and owners and names:
            candidates.extend(owner + "/" + name for owner in owners for name in names)
        for field in fields:
            if field.startswith("q="):
                candidates.extend(re.findall(r"(?:^|\s)repo:([^\s]+)", field[2:]))
    normalized = {candidate.lower() for candidate in candidates}
    if len(normalized) != 1 or not all(valid_slug(value) for value in normalized):
        raise AuthError("Pulse App reads require one explicit repository (--repo, REST path or AIDEVOPS_PULSE_REPO)")
    return normalized.pop()


def app_environment(token, installation, config_dir):
    env = os.environ.copy()
    # No saved gh login, debug headers, or legacy global-App override in this
    # invocation. The original parent's environment remains untouched.
    for key in list(env):
        if key.startswith(("GH_", "GITHUB_", "AIDEVOPS_GITHUB_APP_")):
            env.pop(key)
    env.update(GH_TOKEN=token, GH_HOST="github.com", GH_CONFIG_DIR=config_dir,
               GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1",
               AIDEVOPS_GITHUB_APP_ENABLED="0", AIDEVOPS_PULSE_AUTH_ACTIVE="1",
               AIDEVOPS_GH_AUTH_MODE="github-app",
               AIDEVOPS_GH_AUTH_PRINCIPAL=f"app-installation:{installation}")
    return env


def run_shim(shim, args, env):
    expected = Path(__file__).resolve().with_name("gh")
    if Path(shim).resolve() != expected:
        raise AuthError("Auth resolver can only invoke its sibling gh shim")
    # Fixed absolute sibling script and argv-only gh arguments; never a shell.
    return subprocess.call([str(expected), *args], env=env)  # nosec B603


def execute(shim, args, data, config_path):
    original = os.environ.copy()
    original["AIDEVOPS_PULSE_AUTH_ACTIVE"] = "1"
    kind = operation(args)
    configured = any(entry.get("pulse_auth") is not None for entry in data["initialized_repos"])
    if kind in ("write", "local", "account") or not configured:
        return run_shim(shim, args, original)
    if kind != "read":
        raise AuthError("Unclassified Pulse gh command; explicit read/write support is required")
    repo = repository(args)
    selected = settings(data, repo, config_path)
    if selected is None:
        return run_shim(shim, args, original)
    hosts = option_values(args, "--hostname")
    if any(host != "github.com" for host in hosts) or os.environ.get("GH_HOST", "github.com") != "github.com":
        raise AuthError("Pulse App auth currently supports github.com only")
    if args[0] == "api" and ("://" in api_endpoint(args) or api_endpoint(args).startswith("//")):
        raise AuthError("Use a relative GitHub API endpoint for App reads")
    if any(re.match(r"(?i)authorization\s*:", header) for header in option_values(args, "--header", "-H")):
        raise AuthError("Explicit Authorization headers conflict with repository App auth")
    if "--verbose" in args:
        raise AuthError("Verbose HTTP output is disabled for App-authenticated reads")
    auth, profile = selected
    cache = Path(os.environ.get("AIDEVOPS_GITHUB_APP_CACHE_DIR", Path.home() / ".aidevops/cache/github-app"))
    token = cached_token(profile, auth["installation_id"], repo, cache)
    with tempfile.TemporaryDirectory(prefix="pulse-gh-config-") as config_dir:
        env = app_environment(token["token"], auth["installation_id"], config_dir)
        # Never retry under a different principal, even on 401/403/429.
        return run_shim(shim, args, env)


def auth_status(args, registry_path, config_path):
    data = registry(registry_path)
    selected = settings(data, args.repo, config_path)
    if selected is None:
        print(json.dumps({"provider": "existing", "configured": False}))
        return 0 if args.action == "status" else 1
    auth, profile = selected
    result = {"provider": "github-app", "profile": auth["profile"],
              "app_id": str(profile["app_id"]), "installation_id": str(auth["installation_id"]),
              "scope": "read-only", "writes": "unchanged", "personal_fallback": False}
    if args.action == "check":
        shim = str(Path(__file__).with_name("gh"))
        command = ["api", f"/repos/{args.repo}", "--silent"]
        # Preserve one JSON status document; suppress repository contents.
        rc = execute(shim, command, data, config_path)
        if rc:
            return rc
        result["read_check"] = "passed"
    print(json.dumps(result))
    return 0


def main():
    registry_path, config_path = paths()
    if len(sys.argv) > 2 and sys.argv[1] == "exec-gh":
        if operation(sys.argv[3:]) in ("write", "local", "account"):
            env = dict(os.environ, AIDEVOPS_PULSE_AUTH_ACTIVE="1")
            return run_shim(sys.argv[2], sys.argv[3:], env)
        return execute(sys.argv[2], sys.argv[3:], registry(registry_path), config_path)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("set", "status", "check", "clear"))
    parser.add_argument("repo")
    parser.add_argument("--provider", choices=("github-app",), default="github-app")
    parser.add_argument("--profile")
    parser.add_argument("--installation-id")
    args = parser.parse_args()
    if not valid_slug(args.repo):
        raise AuthError("Repository must be owner/repo")
    if args.action in ("set", "clear"):
        return update_registry(args, registry_path, config_path)
    return auth_status(args, registry_path, config_path)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AuthError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, AuthError) else "Pulse repository authentication failed", file=sys.stderr)
        sys.exit(1)
