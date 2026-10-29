#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Managed Cloudron catalog caller policy shared by release evidence checks."""

import re


MANAGED_WORKFLOW = "marcusquinn/aidevops/.github/workflows/cloudron-catalog-publish-reusable.yml"


def caller_scalar(value):
    """Accept only plain or simply quoted values from the managed template."""
    require(not value.startswith(("&", "*", "!", "{", "[")), "unsupported managed caller value")
    if value.startswith(("'", '"')):
        require(len(value) >= 2 and value[-1:] == value[:1], "invalid managed caller quoting")
        return value[1:-1]
    return value


def caller_mapping_lines(text):
    """Yield mapping entries, excluding comments and block-scalar contents."""
    block_indent = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None and indent > block_indent:
            continue
        block_indent = None
        match = re.fullmatch(r" +([A-Za-z_][A-Za-z0-9_-]*):(?: +(.*))?", line)
        require(match is not None, "unsupported managed caller syntax; use the managed template")
        key, value = match.groups()
        value = (value or "").split(" #", 1)[0].strip()
        if value in ("|", "|-", "|+", ">", ">-", ">+"):
            block_indent = indent
        yield indent, key, value


def caller_jobs(text):
    """Read the template's mapping/block-scalar subset, never guess YAML."""
    jobs = re.findall(r"(?m)^jobs:\s*\n((?:[ \t]+[^\n]*\n|\s*\n|#[^\n]*\n)*)", text + "\n")
    require(len(jobs) == 1, "managed caller requires one canonical jobs mapping")
    root = {}
    stack = [(0, root)]
    for indent, key, value in caller_mapping_lines(jobs[0]):
        while stack[-1][0] >= indent:
            stack.pop()
        require(indent == stack[-1][0] + 2, "invalid managed caller indentation")
        parent = stack[-1][1]
        require(key not in parent, "duplicate managed caller key")
        if not value:
            parent[key] = {}
            stack.append((indent, parent[key]))
        else:
            parent[key] = caller_scalar(value)
    return root


def managed_caller(text, require_secret=False):
    """Bound the reusable signer to an unambiguous exact-source managed caller.

    Unsupported YAML fails closed. Standalone receipt verification keeps its
    existing signer policy; approval requests require the managed caller.
    """
    if MANAGED_WORKFLOW not in text:
        require(not require_secret, "release approval requires the managed catalog caller template")
        return None
    callers = [job for job in caller_jobs(text).values() if isinstance(job, dict)
               and isinstance(job.get("uses"), str) and job["uses"].startswith(MANAGED_WORKFLOW + "@")]
    require(len(callers) == 1, "expected exactly one managed catalog caller")
    caller = callers[0]
    pin = caller["uses"].removeprefix(MANAGED_WORKFLOW + "@")
    require(re.fullmatch(r"[0-9a-f]{40}", pin) is not None, "managed caller must pin a full commit")
    require(isinstance(caller.get("with"), dict) and caller["with"].get("aidevops_ref") == pin,
            "managed caller aidevops_ref must equal its uses pin")
    if require_secret:
        require(isinstance(caller.get("secrets"), dict)
                and caller["secrets"].get("CLOUDRON_RELEASE_PAT") == "${{ secrets.CLOUDRON_RELEASE_PAT }}",
                "managed caller must explicitly pass CLOUDRON_RELEASE_PAT from secrets.CLOUDRON_RELEASE_PAT")
    return pin


class EvidenceError(Exception):
    """An incomplete or inconsistent publication proof."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)
