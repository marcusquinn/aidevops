#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Summarise recent gh requests by credential and Pulse auth route.

Reads only local gh-api-calls.log metadata through the shared aggregator; it
never contacts GitHub and never prints tokens, arguments or response bodies.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from github_app_auth import AuthError
from github_auth_policy import policy

INSTRUMENT = Path(__file__).resolve().with_name("gh-api-instrument.sh")
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_window(value):
    match = re.fullmatch(r"([1-9][0-9]*)([smhd]?)", value)
    if not match:
        raise AuthError("--since must look like 3600, 30m, 1h or 2d")
    return int(match[1]) * UNITS[match[2]]


def aggregate(window, consumer=None):
    env = dict(os.environ, AIDEVOPS_GH_REPORT_CONSUMER=consumer or "")
    with tempfile.TemporaryDirectory(prefix="pulse-auth-usage-") as directory:
        report = Path(directory) / "report.json"
        # Fixed sibling script; the window is a validated integer.
        result = subprocess.run([str(INSTRUMENT), "report", str(report), str(window)],  # nosec B603
                        env=env, check=False, timeout=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode or not report.is_file():
            raise AuthError("gh-api-calls.log report is unavailable")
        value = json.loads(report.read_text())
        if not isinstance(value, dict) or not isinstance(value.get("_meta"), dict):
            raise AuthError("Invalid gh-api-calls.log report")
        return value


def summary(value, group):
    return {name: {"requests": metrics.get("attempted_requests", 0),
                   "failed": metrics.get("failed_attempts", 0),
                   "events": metrics.get("total", 0)}
            for name, metrics in value.get(group, {}).items()}


def usage(since, data, consumer=None):
    window = parse_window(since)
    configured = sorted(entry["slug"] for entry in data["initialized_repos"]
                         if policy(entry) and policy(entry)["read"]["provider"] == "github-app" and entry.get("slug"))
    value = aggregate(window, consumer)
    print(json.dumps({"window_seconds": window, "app_repositories": configured,
                       "source": "local-log", "quota_report": False,
                       "consumer": consumer, "untagged_records_included": consumer is None,
                       "by_consumer": summary(value, "by_consumer"),
                      "by_auth_mode": summary(value, "by_auth_mode"),
                      "by_auth_reason": summary(value, "by_auth_reason")}, indent=2))
    return 0
