#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Repository-scoped Pulse read authentication; writes retain their original auth.

Every Pulse gh invocation receives exactly one route. A classified read of one
repository with ``pulse_auth`` uses that repository's App installation and never
retries under another principal. Every other invocation keeps the existing auth
unchanged, labelled with the reason, so coverage gaps are visible in
gh-api-calls.log instead of failing unrelated Pulse work.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from github_app_auth import AuthError, cached_token
from pulse_auth_config import paths, registry, settings, update_registry
from pulse_auth_route import APP, classify, decide, repository, valid_slug  # noqa: F401 (public API)
from pulse_auth_usage import INSTRUMENT, usage
from pulse_gh_policy import operation  # noqa: F401 (public API used by tests)


def existing_environment(reason):
    return dict(os.environ, AIDEVOPS_PULSE_AUTH_ACTIVE="1", AIDEVOPS_GH_AUTH_REASON=reason)


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
               AIDEVOPS_GH_AUTH_MODE="github-app", AIDEVOPS_GH_AUTH_REASON=APP,
               AIDEVOPS_GH_AUTH_PRINCIPAL=f"app-installation:{installation}")
    return env


def run_shim(shim, args, env):
    expected = Path(__file__).resolve().with_name("gh")
    if Path(shim).resolve() != expected:
        raise AuthError("Auth resolver can only invoke its sibling gh shim")
    # Fixed absolute sibling script and argv-only gh arguments; never a shell.
    return subprocess.call([str(expected), *args], env=env)  # nosec B603


def record_app_failure(installation):
    # Metadata only (no repository, argv or error text) through the shared
    # recorder, so failures appear beside successful App requests.
    env = dict(os.environ, AIDEVOPS_GH_AUTH_REASON=APP,
               AIDEVOPS_GH_AUTH_PRINCIPAL=f"app-installation:{installation}")
    try:
        # Fixed sibling script with constant metadata arguments; never a shell.
        subprocess.run([str(INSTRUMENT), "record", "other", "pulse_repo_auth.py", "github-app",  # nosec B603
                        "other", "pulse-app-auth-failed"], env=env, check=False, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def execute(shim, args, data, config_path):
    reason, selected = decide(args, data, config_path)
    if selected is None:
        return run_shim(shim, args, existing_environment(reason))
    repo, auth, profile = selected
    cache = Path(os.environ.get("AIDEVOPS_GITHUB_APP_CACHE_DIR", Path.home() / ".aidevops/cache/github-app"))
    try:
        token = cached_token(profile, auth["installation_id"], repo, cache)
    except AuthError as error:
        record_app_failure(auth["installation_id"])
        raise AuthError(f"Pulse App read for {repo} failed: {error}; no personal-token retry") from error
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
        reason, _ = decide(command, data, config_path)
        if reason != APP:
            raise AuthError(f"Repository metadata read would use existing auth ({reason}), not the App")
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
        shim, args = sys.argv[2], sys.argv[3:]
        # Non-reads never need the registry; keep their hot path minimal.
        if classify(args) != "read":
            return execute(shim, args, {"initialized_repos": []}, config_path)
        return execute(shim, args, registry(registry_path), config_path)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=("set", "status", "check", "clear", "usage"))
    parser.add_argument("repo", nargs="?")
    parser.add_argument("--provider", choices=("github-app",), default="github-app")
    parser.add_argument("--profile")
    parser.add_argument("--installation-id")
    parser.add_argument("--since", default="1h", help="usage window, e.g. 30m, 1h, 2d (default 1h)")
    args = parser.parse_args()
    if args.action == "usage":
        return usage(args.since, registry(registry_path))
    if not args.repo or not valid_slug(args.repo):
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
