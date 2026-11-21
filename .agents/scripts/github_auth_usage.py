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
# t19233: logged REST-core cost per hour at or above this share of the
# authoritative primary limit means the governor, not demand, sets the pace.
REST_CORE_SATURATION_SHARE = 0.75


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


def _app_read_bound(entry):
    routes = policy(entry)
    return bool(routes) and routes["read"]["provider"] == "github-app"


def _pulse_slugs(data):
    for entry in data.get("initialized_repos", []):
        slug = entry.get("slug") or ""
        if entry.get("pulse") is True and entry.get("local_only") is not True and slug.count("/") == 1:
            yield slug, entry


def routing_opportunity(report, data):
    """GH#38273: how much known quota cost an App read binding could move off the PAT."""
    reasons = report.get("by_auth_reason", {})
    costs = [metrics.get("known_quota_cost") for metrics in reasons.values()]
    routable = reasons.get("not-configured", {})
    known_total = sum(cost for cost in costs if isinstance(cost, int))
    routable_cost = routable.get("known_quota_cost")
    usable = isinstance(routable_cost, int) and known_total > 0 and all(isinstance(cost, int) for cost in costs)
    unbound = sorted({slug.split("/")[0] for slug, entry in _pulse_slugs(data) if not _app_read_bound(entry)})
    min_remaining = report.get("budget_by_pool", {}).get("rest-core", {}).get("min_remaining")
    return {"routable_attempts": routable.get("attempted_requests", 0),
            "routable_known_quota_cost": routable_cost if usable else None,
            "known_quota_cost": known_total if usable else None,
            "routable_share": round(routable_cost / known_total, 3) if usable else None,
            "rest_core_min_remaining": min_remaining if isinstance(min_remaining, int) else None,
            **rest_core_saturation(report, _rest_core_limit()),
            "owners_without_app_read": unbound}


def _hard_floor():
    for name in ("AIDEVOPS_PULSE_REST_CORE_BUDGET_HARD_FLOOR", "AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR"):
        value = os.environ.get(name, "")
        if value.isdigit():
            return int(value)
    return 0


def _rest_core_limit():
    """Authoritative REST-core limit from the Pulse probe cache, or None."""
    path = Path(os.environ.get("AIDEVOPS_PULSE_REST_CORE_CACHE")
                or Path.home() / ".aidevops" / "cache" / "pulse-rest-core.json")
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict) or value.get("resource") != "core":
        return None
    limit = value.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
        return None
    return limit


def rest_core_saturation(report, limit):
    """t19233: the governor paces before quota hits zero, so measure the hourly
    share of the primary limit that logged REST-core calls consume."""
    meta = report.get("_meta", {})
    window = meta.get("effective_window_seconds") or meta.get("window_seconds")
    cost = report.get("by_api_pool", {}).get("rest-core", {}).get("known_quota_cost")
    if not isinstance(window, int) or window <= 0 or not isinstance(cost, int):
        return {"rest_core_limit": limit, "rest_core_cost_per_hour": None, "rest_core_saturation": None}
    per_hour = round(cost * 3600 / window)
    return {"rest_core_limit": limit, "rest_core_cost_per_hour": per_hour,
            "rest_core_saturation": round(per_hour / limit, 3) if limit else None}


def advisory_due(opportunity, floor):
    share, low = opportunity["routable_share"], opportunity["rest_core_min_remaining"]
    if share is None or low is None or not opportunity["owners_without_app_read"]:
        return False
    saturation = opportunity.get("rest_core_saturation")
    saturated = isinstance(saturation, float) and saturation >= REST_CORE_SATURATION_SHARE
    return share >= 0.5 and (low == 0 or low < floor or saturated)


def advisory_text(opportunity):
    share = round(opportunity["routable_share"] * 100)
    owners = ", ".join(opportunity["owners_without_app_read"])
    # t19020: line 1 is the whole greeting entry, so it is [WARN]-classified
    # and names the setup command itself; later lines are detail.
    return "\n".join([
        f"[WARN] GitHub REST quota is the pulse ceiling: {share}% of known API cost could move to a GitHub App"
        f" read route. Run `aidevops github auth app create --owner OWNER` for: {owners}",
        f"Owners without an App read binding: {owners}",
        "An App installation has its own primary rate limit, so pulse reads stop competing with your token.",
        "Setup (owner clicks Create, then Install; binding and checks are automatic):",
        "  aidevops github auth app create --owner OWNER [--install-on OTHER_OWNER ...]",
        "Existing App profile: aidevops github auth app bind --profile NAME",
        "Details: reference/github-auth.md 'Fast path'. Evidence: aidevops github auth advise",
        "This notice is removed automatically once the conditions no longer hold.",
    ]) + "\n"


def advisory_path():
    return Path(os.environ.get("AIDEVOPS_ADVISORIES_DIR") or Path.home() / ".aidevops" / "advisories") / "github-app-read-routing.advisory"


def write_advisory(opportunity, floor, path):
    if not advisory_due(opportunity, floor):
        if path.exists():
            path.unlink()
            return "removed"
        return "not-due"
    path.parent.mkdir(parents=True, exist_ok=True)
    text = advisory_text(opportunity)
    if path.is_file() and path.read_text() == text:
        return "unchanged"
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".github-app-advise.", delete=False) as handle:
        handle.write(text)
    os.chmod(handle.name, 0o644)
    os.replace(handle.name, path)
    return "written"


def advise(since, data, write=False):
    window = parse_window(since)
    opportunity = routing_opportunity(aggregate(window), data)
    floor = _hard_floor()
    result = {"window_seconds": window, "app_routing_opportunity": opportunity,
              "rest_core_hard_floor": floor, "advisory_due": advisory_due(opportunity, floor)}
    if write:
        result["advisory"] = write_advisory(opportunity, floor, advisory_path())
    print(json.dumps(result, indent=2))
    return 0


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
                      "by_auth_reason": summary(value, "by_auth_reason"),
                      "app_routing_opportunity": routing_opportunity(value, data)}, indent=2))
    return 0
