#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only GitHub autonomy outcomes for owners in the local managed registry."""

import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from itertools import product
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from autonomy_report_text import print_text

TARGET_INTERACTIVE_SHARE = 0.15
TARGET_WORKER_WASTE = 0.05
TARGET_WORKER_ISSUE_MERGE_P90_HOURS = 24
TARGET_IDLE_7D_PULSE_ON = 0
TARGET_BLOCKED_STALE_14D = 0

WEEKLY = {
    "worker": "is:pr is:merged label:origin:worker merged:{span}",
    "interactive": "is:pr is:merged label:origin:interactive merged:{span}",
    "all": "is:pr is:merged merged:{span}",
    "worker_closed_unmerged": "is:pr is:closed is:unmerged label:origin:worker closed:{span}",
}
QUEUE = {
    "available": "is:issue is:open label:auto-dispatch label:status:available",
    "available_idle_7d": "is:issue is:open label:auto-dispatch label:status:available updated:<{d7}",
    "blocked": "is:issue is:open label:status:blocked",
    "blocked_stale_14d": "is:issue is:open label:status:blocked updated:<{d14}",
    "hold_for_review": "is:pr is:open label:hold-for-review",
    "needs_maintainer_review": "is:open label:needs-maintainer-review",
}
NOTES = [
    "Counts are point-in-time GitHub search totals, not a transactional snapshot.",
    "Search totals above 1,000 are exact counts; lead-time samples cap at 100 PRs per row/origin.",
    "PRs without origin labels contribute only to all; dual-origin PRs count in both origins.",
    "Windows are the latest completed Monday-Sunday UTC weeks; queue health is current.",
    "Owner rows cover the whole owner, including unregistered repos; only eligible registry entries define local pulse state.",
    "Lead times sample latest-updated merged PRs in the week and the first closing issue, omitting missing references.",
    "Targets are initial heuristics, not gates; missing ratios/percentiles are null (n/a in text).",
]


def graphql(query):
    """Run one read query, rejecting partial responses and avoiding retries."""
    executable = shutil.which("gh")
    if executable is None:
        raise ValueError("gh is not available on PATH")
    result = subprocess.run(  # nosec B603 -- resolved gh, fixed read-only API argv, no shell
        [str(Path(executable).absolute()), "api", "graphql", "-f", "query=" + query],
        capture_output=True, text=True, timeout=120, check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "GitHub GraphQL request failed")
    response = json.loads(result.stdout)
    if response.get("errors"):
        raise ValueError(json.dumps(response["errors"]))
    return response["data"]


def counts(queries):
    """Batch up to forty count-only searches per request."""
    items = list(queries.items())
    output = {}
    for start in range(0, len(items), 40):
        batch = items[start:start + 40]
        fields = [
            f'q{i}:search(type:ISSUE,query:{json.dumps(query)},first:0){{issueCount}}'
            for i, (_, query) in enumerate(batch)
        ]
        data = graphql("query{" + " ".join(fields) + "}")
        for i, (key, _) in enumerate(batch):
            output[key] = data[f"q{i}"]["issueCount"]
    return output


def registry(path):
    entries = json.loads(path.read_text())["initialized_repos"]
    if not isinstance(entries, list):
        raise ValueError("initialized_repos must be an array")
    repos = {}
    for entry in entries:
        slug = entry.get("slug", "")
        if entry.get("local_only") is True or entry.get("role") != "maintainer":
            continue
        if "/" not in slug:
            continue
        if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", slug):
            raise ValueError("Invalid repository slug in registry")
        repos[slug.lower()] = entry.get("pulse") is True
    return repos


def scopes(repos, framework):
    rows = {framework: "repo:" + framework}
    for owner in sorted({slug.split("/")[0] for slug in repos}):
        data = graphql("query{repositoryOwner(login:" + json.dumps(owner) + "){__typename}}")
        kind = data["repositoryOwner"]["__typename"]
        scope = {"User": "user:", "Organization": "org:"}[kind] + owner
        rows[owner] = scope + " -repo:" + framework
    return rows


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return {"n": 0, "p50_hours": None, "p90_hours": None}
    # Linear interpolation, including the single-sample case.
    def percentile(fraction):
        index = (len(ordered) - 1) * fraction
        lower = math.floor(index)
        upper = math.ceil(index)
        return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower), 3)
    return {"n": len(ordered), "p50_hours": percentile(0.5), "p90_hours": percentile(0.9)}


def lead_time(query):
    data = graphql(
        "query{search(type:ISSUE,query:" + json.dumps(query + " sort:updated-desc")
        + ",first:100){nodes{... on PullRequest{createdAt mergedAt "
        + "closingIssuesReferences(first:1){nodes{createdAt}}}}}}"
    )
    opened, issues = [], []
    nodes = data["search"]["nodes"]
    for pr in nodes:
        merged = datetime.fromisoformat(pr["mergedAt"].replace("Z", "+00:00"))
        created = datetime.fromisoformat(pr["createdAt"].replace("Z", "+00:00"))
        opened.append((merged - created).total_seconds() / 3600)
        for issue in pr["closingIssuesReferences"]["nodes"]:
            created = datetime.fromisoformat(issue["createdAt"].replace("Z", "+00:00"))
            issues.append((merged - created).total_seconds() / 3600)
    return {"sample_size": len(nodes), "pr_opened_to_merged": percentiles(opened),
            "issue_created_to_merged": percentiles(issues)}


def week_span(window):
    start, stop = window
    return f"{start}..{stop - timedelta(days=1)}"


def count_queries(scope_rows, windows, repos, now):
    queries = {}
    for window, row, metric in product(windows, scope_rows, WEEKLY):
        queries[(str(window[0]), row, metric)] = scope_rows[row] + " " + WEEKLY[metric].format(span=week_span(window))
    dates = {"d7": (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "d14": (now - timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    for row, metric in product(scope_rows, QUEUE):
        queries[("queue", row, metric)] = scope_rows[row] + " " + QUEUE[metric].format(**dates)
    for row, scope in scope_rows.items():
        if row in repos:
            # A registered single-repository scope has no unregistered subset.
            continue
        exclusions = "".join(" -repo:" + slug for slug in repos
                             if row == slug.split("/")[0])
        queries[("unregistered", row)] = scope + exclusions + " " + QUEUE["available_idle_7d"].format(**dates)
    for slug in repos:
        queries[("pulse", slug)] = "repo:" + slug + " " + QUEUE["available_idle_7d"].format(**dates)
    return queries


def weekly_rows(scope_rows, windows, totals):
    rows = []
    for window, row in product(windows, scope_rows):
        start, stop = window
        values = {metric: totals[(str(start), row, metric)] for metric in WEEKLY}
        values["interactive_share"] = ratio(values["interactive"], values["worker"] + values["interactive"])
        values["worker_waste"] = ratio(values["worker_closed_unmerged"], values["worker"] + values["worker_closed_unmerged"])
        rows.append({"week_start": str(start), "week_end": str(stop - timedelta(days=1)),
                     "scope": row, **values})
    return rows


def queue_rows(scope_rows, repos, framework, totals):
    pulse = defaultdict(lambda: {"on": 0, "off": 0, "not_registered": 0})
    for slug, enabled in repos.items():
        row = framework if slug == framework else slug.split("/")[0]
        pulse[row][{True: "on", False: "off"}[enabled]] += totals[("pulse", slug)]
    rows = []
    for row in scope_rows:
        values = {metric: totals[("queue", row, metric)] for metric in QUEUE}
        split = pulse[row]
        split["not_registered"] = 0 if row in repos else totals[("unregistered", row)]
        rows.append({"scope": row, **values, "available_idle_7d_by_pulse": split})
    return rows


def report(repos, framework, weeks, now):
    scope_rows = scopes(repos, framework)
    end = now.date() - timedelta(days=now.weekday())
    windows = [(end - timedelta(weeks=i + 1), end - timedelta(weeks=i))
               for i in reversed(range(weeks))]
    totals = counts(count_queries(scope_rows, windows, repos, now))
    leads = []
    for row, origin in product(scope_rows, ("worker", "interactive")):
        query = scope_rows[row] + " " + WEEKLY[origin].format(span=week_span(windows[-1]))
        leads.append({"scope": row, "origin": origin, **lead_time(query)})
    return {
        "window": {"start": str(windows[0][0]), "end_exclusive": str(end),
                   "weeks": weeks, "generated_at": now.isoformat()},
        "rows": weekly_rows(scope_rows, windows, totals), "lead_times": leads,
        "queue": queue_rows(scope_rows, repos, framework, totals),
        "targets": {"interactive_share_lt": TARGET_INTERACTIVE_SHARE,
                    "worker_waste_lt": TARGET_WORKER_WASTE,
                    "worker_issue_merge_p90_hours_lt": TARGET_WORKER_ISSUE_MERGE_P90_HOURS,
                    "idle_7d_pulse_on_eq": TARGET_IDLE_7D_PULSE_ON,
                    "blocked_stale_14d_eq": TARGET_BLOCKED_STALE_14D},
        "notes": NOTES,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weeks", type=int, default=8, help="Completed UTC weeks (1-52; default 8)")
    parser.add_argument("--framework-repo", default="marcusquinn/aidevops")
    parser.add_argument("--json", action="store_true", help="Print one JSON object; unavailable values are null")
    args = parser.parse_args()
    if not 1 <= args.weeks <= 52:
        parser.error("--weeks must be between 1 and 52")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", args.framework_repo):
        parser.error("--framework-repo must be owner/repo")
    try:
        path = Path(os.environ.get("REPOS_FILE", str(Path.home() / ".config/aidevops/repos.json")))
        result = report(registry(path), args.framework_repo.lower(), args.weeks, datetime.now(timezone.utc))
    except OSError:
        print("autonomy-report: cannot read registry or execute gh", file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print("autonomy-report: GitHub query timed out", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError) as error:
        print(f"autonomy-report: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, allow_nan=False))
    else:
        print_text(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
