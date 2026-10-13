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

SLUG = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
READS = {"issue": {"list", "view"}, "pr": {"list", "view", "checks", "diff"},
         "repo": {"view"}, "search": {"issues", "prs", "code", "commits"},
         "run": {"list", "view"}, "workflow": {"list", "view"},
         "release": {"list", "view"}}
WRITES = {"issue": {"create", "edit", "comment", "close", "reopen", "delete", "transfer", "pin", "unpin", "lock", "unlock"},
          "pr": {"create", "edit", "comment", "close", "reopen", "merge", "review", "ready", "lock", "unlock", "update-branch"},
          "run": {"cancel", "rerun", "delete"}, "workflow": {"run", "enable", "disable"},
         "release": {"create", "edit", "delete", "upload"}}


def valid_slug(value):
    return bool(SLUG.fullmatch(value)) and all(part not in (".", "..") for part in value.split("/"))


def option_values(args, long, short=None):
    result = []
    for index, arg in enumerate(args):
        if arg in (long, short):
            if index + 1 >= len(args):
                raise AuthError("Missing gh option value")
            result.append(args[index + 1])
        elif arg.startswith(long + "="):
            result.append(arg[len(long) + 1:])
        elif short and arg.startswith(short) and len(arg) > len(short):
            result.append(arg[len(short):].lstrip("="))
    return result


def api_endpoint(args):
    value_options = {"--method", "-X", "--field", "-F", "--raw-field", "-f",
                     "--header", "-H", "--input", "--hostname", "--jq", "-q",
                     "--template", "-t", "--preview", "-p", "--cache"}
    boolean_options = {"--include", "-i", "--paginate", "--slurp", "--silent", "--verbose"}
    endpoints = []
    skip = False
    for arg in args[1:]:
        if skip:
            skip = False
        elif arg in value_options:
            skip = True
        elif arg in boolean_options:
            continue
        elif arg.startswith("-"):
            if not any(arg.startswith(flag + "=") if flag.startswith("--") else arg.startswith(flag)
                       for flag in value_options):
                return ""
        else:
            endpoints.append(arg)
    return endpoints[0] if not skip and len(endpoints) == 1 else ""


def graphql_operation(fields, inputs):
    queries = [value[6:] for value in fields if value.startswith("query=")]
    if inputs or len(queries) != 1 or any(value.startswith("query=@") for value in fields):
        return "unknown"
    # Strip strings/comments; mixed or unfamiliar documents fail closed.
    query = re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|#[^\n]*', " ", queries[0]).strip()
    if re.match(r"mutation\b", query) and not re.search(r"\bquery\b", query):
        return "write"
    if re.search(r"\b(?:mutation|subscription)\b", query):
        return "unknown"
    if query.startswith("{") or re.match(r"query\b", query):
        return "read"
    return "unknown"


def api_operation(args):
    # Parse flags without reading request files or guessing dynamic endpoints.
    endpoint = api_endpoint(args)
    if not endpoint:
        return "unknown"
    methods = option_values(args, "--method", "-X")
    fields = option_values(args, "--field", "-F") + option_values(args, "--raw-field", "-f")
    inputs = option_values(args, "--input")
    method = methods[-1].upper() if methods else ("POST" if fields or inputs else "GET")
    if endpoint.strip("/") == "graphql":
        return graphql_operation(fields, inputs)
    if method in ("GET", "HEAD"):
        # Maintainer identity is still the write actor. Unscoped budget probes
        # describe that existing account, not any particular App installation.
        account = endpoint.strip("/") == "user" or (
            endpoint.strip("/") == "rate_limit" and not os.environ.get("AIDEVOPS_PULSE_REPO"))
        return "account" if account else "read"
    if method in ("POST", "PUT", "PATCH", "DELETE"):
        return "write"
    return "unknown"


def operation(args):
    if not args or args[0] in ("--version", "version", "help"):
        return "local"
    if len(args) > 1 and args[1] in READS.get(args[0], set()):
        return "read"
    if len(args) > 1 and args[1] in WRITES.get(args[0], set()):
        return "write"
    return api_operation(args) if args[0] == "api" else "unknown"


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
