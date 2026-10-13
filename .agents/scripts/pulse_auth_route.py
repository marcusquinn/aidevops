#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Pure routing decision for Pulse gh invocations (no credentials, no I/O).

A classified read of exactly one repository with ``pulse_auth`` routes to that
repository's App. Every other invocation keeps existing auth with a reason
recorded in gh-api-calls.log field 18.
"""

import os
import re

from github_app_auth import AuthError
from pulse_auth_config import any_configured, settings
from pulse_gh_policy import api_endpoint, operation, option_values

SLUG = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
APP = "app"
# Existing-auth reasons for non-read operations.
REASONS = {"write": "write", "local": "local", "account": "account", "unknown": "unclassified"}


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
    endpoint = api_endpoint(args) if args[0] == "api" else ""
    hosts = option_values(args, "--hostname") + [os.environ.get("GH_HOST", "github.com")]
    headers = option_values(args, "--header", "-H")
    checks = (("other-host", any(host != "github.com" for host in hosts)),
              ("absolute-url", "://" in endpoint or endpoint.startswith("//")),
              ("explicit-auth", any(re.match(r"(?i)authorization\s*:", header) for header in headers)),
              ("verbose", "--verbose" in args))
    return next((reason for reason, matched in checks if matched), None)


def read_scope(args, data):
    """Return (reason, repo) for a read; repo is set only when exactly one is named."""
    if not any_configured(data):
        return "not-configured", None
    try:
        return None, repository(args)
    except AuthError:
        return "unscoped", None


def decide(args, data, config_path):
    """Return (reason, selection); selection is (repo, auth, profile) only for App reads."""
    kind = classify(args)
    reason, repo = read_scope(args, data) if kind == "read" else (REASONS.get(kind, "unclassified"), None)
    selected = settings(data, repo, config_path) if repo else None
    if repo and selected is None:
        reason = "not-configured"
    reason = reason or caller_override(args)
    return (reason, None) if reason else (APP, (repo, *selected))
