#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared checkpoint event parsing and authenticated author predicates."""

import datetime as dt
import re

TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
EVENTS = ("DISPATCH_CLAIM ", "DISPATCH_LEASE ", "CLAIM_RELEASED ",
          "Dispatching worker", "Interactive session claimed")


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def normalized_attempt(value):
    """Accept the launcher's raw ID without changing the attempt's identity."""
    if not isinstance(value, str) or not value or value == "attempt:":
        return ""
    return value if value.startswith("attempt:") else "attempt:" + value


def fields(line):
    pairs = re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line)
    parsed = dict(pairs)
    return parsed if len(parsed) == len(pairs) else {}


def author_trusted(comment, trusted_logins=()):
    #aidevops:trust-boundary — logins come only from authenticated repo permissions.
    elevated = {"CONTRIBUTOR", "NONE"} if comment.get("user", {}).get("login") in trusted_logins else set()
    return comment.get("author_association") in TRUSTED | elevated


def trusted(comment, trusted_logins=()):
    return all((author_trusted(comment, trusted_logins), bool(comment.get("user", {}).get("login")),
                comment.get("updated_at", comment.get("created_at")) == comment.get("created_at")))


def events(comments, start, end, trusted_logins=()):
    for comment in comments:
        # Edited trusted coordination must still invalidate a history, not vanish.
        if not start < comment["id"] < end or not author_trusted(comment, trusted_logins):
            continue
        for line in comment["body"].splitlines():
            if line.startswith(EVENTS):
                yield comment, line, fields(line)
