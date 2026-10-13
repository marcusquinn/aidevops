# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Classify Pulse gh commands without invoking a transport or reading credentials."""

import os
import re

from github_app_auth import AuthError

READS = {"issue": {"list", "view"}, "pr": {"list", "view", "checks", "diff"},
         "repo": {"view"}, "search": {"issues", "prs", "code", "commits"},
         "run": {"list", "view"}, "workflow": {"list", "view"},
         "release": {"list", "view"}}
WRITES = {"issue": {"create", "edit", "comment", "close", "reopen", "delete", "transfer", "pin", "unpin", "lock", "unlock"},
          "pr": {"create", "edit", "comment", "close", "reopen", "merge", "review", "ready", "lock", "unlock", "update-branch"},
          "run": {"cancel", "rerun", "delete"}, "workflow": {"run", "enable", "disable"},
          "release": {"create", "edit", "delete", "upload"}}


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
    # Keep each long option paired with its alias so the two forms cannot drift.
    aliases = {"--method": "-X", "--field": "-F", "--raw-field": "-f",
               "--header": "-H", "--jq": "-q", "--template": "-t", "--preview": "-p"}
    value_options = set(aliases) | set(aliases.values()) | {"--input", "--hostname", "--cache"}
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
