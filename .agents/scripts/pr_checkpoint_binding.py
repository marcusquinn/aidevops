#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Revision binding metadata and non-authorizing approval diagnostics."""

import datetime as dt
import hashlib
import json
import re

from pr_checkpoint_events import timestamp, trusted

PREFIX = "CHECKPOINT_CONTINUATION_APPROVED "


def binding(data):
    issue, pr = data["issue"], data["pr"]
    return {"repo": data["repo"], "issue": issue["number"], "pr": pr["number"],
            "head": pr["headRefOid"], "ref": pr["headRefName"],
            "runner": pr["author"]["login"],
            "brief_sha256": hashlib.sha256(issue["body"].encode()).hexdigest()}


def sorted_comments(data):
    comments = data["comments"]
    if comments and isinstance(comments[0], list):
        comments = [c for page in comments for c in page]
    return sorted(comments, key=lambda c: (c["created_at"], c["id"]))


def newest_binding_mismatch(data):
    """Report only fixed field names from the newest trusted unedited approval."""
    try:
        comments = (c for c in reversed(sorted_comments(data))
                    if trusted(c, data.get("trusted_logins", ())) and
                    len([line for line in c["body"].splitlines() if line.startswith(PREFIX)]) == 1)
        comment = next(comments)
        line = next(line for line in comment["body"].splitlines() if line.startswith(PREFIX))
        approval = json.loads(line[len(PREFIX):])
        keys = [key for key, value in binding(data).items() if approval.get(key) != value]
        now = data.get("now", dt.datetime.now(dt.timezone.utc).timestamp())
        age = now - timestamp(comment["created_at"])
        checks = {"expired": not 0 <= age <= 86400,
                  "attempt_malformed": not re.match(r"^attempt:", str(approval.get("attempt")))}
        return keys + [key for key, failed in checks.items() if failed], comment["id"]
    except (ValueError, KeyError, TypeError, OverflowError, StopIteration, AttributeError):
        return None


def binding_diagnostic(data):
    mismatch = newest_binding_mismatch(data)
    if not mismatch or not mismatch[0]:
        return ""
    comment_id = mismatch[1]
    if not isinstance(comment_id, int) or isinstance(comment_id, bool):
        return ""
    if comment_id <= 0:
        return ""
    return f"APPROVAL_BINDING_MISMATCH keys={','.join(mismatch[0])} approval_comment={comment_id}"
