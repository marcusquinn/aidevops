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
import re
import subprocess
import sys
import tempfile

from github_app_auth import AuthError, cached_token
from pulse_auth_config import any_configured, paths, registry, settings, update_registry
from pulse_gh_policy import api_endpoint, operation, option_values

SLUG = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
APP = "app"
# Existing-auth reasons recorded in gh-api-calls.log (field 18).
REASONS = {"write": "write", "local": "local", "account": "account", "unknown": "unclassified"}
INSTRUMENT = Path(__file__).resolve().with_name("gh-api-instrument.sh")


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


def classify(args):
    # Malformed argv is the caller's problem to report; it is not an App read.
    try:
        return operation(args)
    except AuthError:
        return "unknown"


def caller_override(args):
    """Return a reason when the caller pins transport details an App read cannot honour."""
    hosts = option_values(args, "--hostname")
    if any(host != "github.com" for host in hosts) or os.environ.get("GH_HOST", "github.com") != "github.com":
        return "other-host"
    endpoint = api_endpoint(args) if args[0] == "api" else ""
    if "://" in endpoint or endpoint.startswith("//"):
        return "absolute-url"
    if any(re.match(r"(?i)authorization\s*:", header) for header in option_values(args, "--header", "-H")):
        return "explicit-auth"
    if "--verbose" in args:
        return "verbose"
    return None


def decide(args, data, config_path):
    """Return (reason, selection); selection is (repo, auth, profile) only for App reads."""
    kind = classify(args)
    if kind != "read":
        return REASONS.get(kind, "unclassified"), None
    if not any_configured(data):
        return "not-configured", None
    try:
        repo = repository(args)
    except AuthError:
        return "unscoped", None
    selected = settings(data, repo, config_path)
    if selected is None:
        return "not-configured", None
    override = caller_override(args)
    if override:
        return override, None
    return APP, (repo, *selected)


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


def parse_window(value):
    match = re.fullmatch(r"([1-9][0-9]*)([smhd]?)", value)
    if not match:
        raise AuthError("--since must look like 3600, 30m, 1h or 2d")
    return int(match[1]) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[match[2]]


def usage(args, registry_path):
    """Summarise recent gh requests by credential and routing reason."""
    window = parse_window(args.since)
    data = registry(registry_path)
    configured = sorted(entry["slug"] for entry in data["initialized_repos"]
                        if entry.get("pulse_auth") is not None and entry.get("slug"))
    with tempfile.TemporaryDirectory(prefix="pulse-auth-usage-") as directory:
        report = Path(directory) / "report.json"
        # Fixed sibling script; the window is a validated integer.
        subprocess.run([str(INSTRUMENT), "report", str(report), str(window)],  # nosec B603
                       check=False, timeout=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not report.is_file():
            raise AuthError("gh-api-calls.log report is unavailable")
        value = json.loads(report.read_text())

    def summary(group):
        return {name: {"requests": metrics.get("attempted_requests", 0),
                       "failed": metrics.get("failed_attempts", 0),
                       "events": metrics.get("total", 0)}
                for name, metrics in value.get(group, {}).items()}

    print(json.dumps({"window_seconds": window, "app_repositories": configured,
                      "by_auth_mode": summary("by_auth_mode"),
                      "by_auth_reason": summary("by_auth_reason")}, indent=2))
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
        return usage(args, registry_path)
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
