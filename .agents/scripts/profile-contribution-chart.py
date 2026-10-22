#!/usr/bin/env python3
"""Publish aggregate-only GitHub contribution charts with the profile README.

SPDX-License-Identifier: MIT
SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from profile_contribution_data import (
    _valid_month_totals as _valid_month_totals,
    compact as compact,
    render_svg as render_svg,
    valid_history as valid_history,
)

ASSET_DIR = Path("assets/contributions")
FILES = ("total-light.svg", "total-dark.svg", "total.json")
START = "<!-- TOTAL-CONTRIBUTIONS-START -->"
END = "<!-- TOTAL-CONTRIBUTIONS-END -->"
UTC = dt.timezone.utc


class FetchError(Exception):
    """Unverified or unavailable remote data; retain the published chart."""


def graphql(query, login):
    """Use gh's credential handling; never expose raw API errors or credentials."""
    try:
        result = subprocess.run(
            ["gh", "api", "graphql", "--input", "-"],
            input=json.dumps({"query": query, "variables": {"login": login}}),
            capture_output=True, text=True, timeout=60, check=True,
        )
        payload = json.loads(result.stdout)
        if not isinstance(payload, dict) or payload.get("errors"):
            raise FetchError("GitHub returned incomplete contribution data")
        user = payload["data"]["user"]
        if not isinstance(user, dict) or user.get("login", "").casefold() != login.casefold():
            raise FetchError("GitHub profile identity could not be verified")
        return user
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        raise FetchError("GitHub contribution lookup unavailable") from exc


def monthly_windows(created, today):
    """Disjoint UTC months, ending at yesterday's final second (never future days)."""
    current = dt.date(created.year, created.month, 1)
    while current < today:
        following = dt.date(current.year + (current.month == 12), current.month % 12 + 1, 1)
        end = dt.datetime.combine(min(following, today), dt.time(), UTC) - dt.timedelta(seconds=1)
        yield current.strftime("%Y-%m"), current.isoformat() + "T00:00:00Z", end.strftime("%Y-%m-%dT%H:%M:%SZ")
        current = following


def fetch_history(login, today, client=graphql):
    identity = client("query($login:String!){user(login:$login){login createdAt}}", login)
    try:
        created = dt.date.fromisoformat(identity["createdAt"][:10])
        if not dt.date(2007, 1, 1) <= created <= today:
            raise ValueError("invalid account creation date")
    except (KeyError, ValueError, TypeError) as exc:
        raise FetchError("GitHub account creation date unavailable") from exc
    windows = list(monthly_windows(created, today))
    if len(windows) > 400:
        raise FetchError("Contribution history exceeds the bounded query window")
    points, cumulative = [], 0
    for offset in range(0, len(windows), 12):
        batch = windows[offset:offset + 12]
        aliases = [
            f'm{i}:contributionsCollection(from:"{begin}",to:"{end}")'
            + "{contributionCalendar{totalContributions}}"
            for i, (_, begin, end) in enumerate(batch)
        ]
        response = client("query($login:String!){user(login:$login){login " + " ".join(aliases) + "}}", login)
        for i, (month, _, _) in enumerate(batch):
            collection = response.get(f"m{i}")
            if not isinstance(collection, dict):
                raise FetchError("Missing contribution month")
            calendar = collection.get("contributionCalendar")
            total = calendar.get("totalContributions") if isinstance(calendar, dict) else None
            if type(total) is not int or total < 0:
                raise FetchError("Incomplete contribution totals")
            cumulative += total
            # Only public aggregate counts: never publish individual private buckets.
            points.append({"month": month, "total": total, "cumulative": cumulative})
    return {
        "schema": "aidevops.total-contributions/v1", "user": login,
        "updated": today.isoformat(), "through": (today - dt.timedelta(days=1)).isoformat(),
        "metric": "GitHub contributionCalendar.totalContributions",
        "total": cumulative, "months": points,
    }


def chart_block(login):
    return f'''{START}
<div align="center">
  <a href="https://commit-history.com/{login}?metric=total" target="_blank" rel="noopener noreferrer">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/contributions/total-dark.svg" />
      <img alt="{login}'s cumulative total GitHub contributions" src="assets/contributions/total-light.svg" width="960" />
    </picture>
  </a>
</div>

[Verify on commit-history.com](https://commit-history.com/{login}?metric=total) · [Chart data](assets/contributions/total.json)

Includes commits, issues, pull requests, reviews, repositories, and restricted contributions. Refreshed daily through the prior UTC day; commit-history.com may use a different refresh cutoff. GitHub controls link navigation—Ctrl/Cmd-click opens verification in a new tab.
{END}'''


def migrate_readme(text, login):
    block = chart_block(login)
    if START in text or END in text:
        if text.count(START) != 1 or text.count(END) != 1 or text.index(END) < text.index(START):
            raise ValueError("Ambiguous contribution chart markers")
        return text[:text.index(START)] + block + text[text.index(END) + len(END):]
    # Only replace the known generated chart container, not arbitrary pictures.
    pattern = r'<div align="center">(?:(?!</div>).)*https://commit-history\.com/embed/' + re.escape(login) + r'(?=[?"\s])(?:(?!</div>).)*</div>'
    matches = list(re.finditer(pattern, text, re.DOTALL))
    if len(matches) > 1:
        raise ValueError("Multiple legacy contribution charts")
    if matches:
        match = matches[0]
        return text[:match.start()] + block + text[match.end():]
    return text.rstrip() + "\n\n" + block + "\n"


def safe_paths(repo, readme):
    """Fail closed on symlinked artifacts, including ancestor directories."""
    for path in [repo / "assets", repo / ASSET_DIR, readme] + [repo / ASSET_DIR / name for name in FILES]:
        if path.is_symlink() or (path.exists() and not (path.is_file() or path.is_dir())):
            raise ValueError("Unsafe contribution chart artifact path")
    if not readme.is_file():
        raise ValueError("Profile README is not a regular file")


def refresh(repo, readme, login, dry_run=False, today=None, client=graphql):
    today = today or dt.datetime.now(UTC).date()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", login):
        raise ValueError("Invalid GitHub username")
    safe_paths(repo, readme)
    destination = repo / ASSET_DIR
    cached = None
    try:
        cached = json.loads((destination / "total.json").read_text())
    except (OSError, ValueError):
        pass
    fresh = valid_history(cached, login, today) and cached["updated"] == today.isoformat()
    if fresh and all((destination / name).is_file() for name in FILES):
        data = cached
    else:
        try:
            data = fetch_history(login, today, client)
        except FetchError:
            print("Warning: GitHub chart refresh unavailable; retaining the last successful chart", file=sys.stderr)
            return False
    updated_readme = migrate_readme(readme.read_text(), login)
    payloads = {
        destination / "total-light.svg": render_svg(data),
        destination / "total-dark.svg": render_svg(data, dark=True),
        destination / "total.json": json.dumps(data, indent=2) + "\n",
        readme: updated_readme,
    }
    changed = {path: text for path, text in payloads.items() if not path.exists() or path.read_text() != text}
    if dry_run:
        print(f"Contribution chart preview: total={data['total']} through={data['through']} changed_files={len(changed)}")
        return bool(changed)
    # Fetch, validate, render and migrate everything before any artifact changes.
    # An I/O failure aborts the publisher, so no partial set reaches the remote.
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".contribution-chart-", dir=repo) as staging:
        for index, (path, text) in enumerate(changed.items()):
            staged = Path(staging) / str(index)
            staged.write_text(text)
        for index, path in enumerate(changed):
            os.replace(Path(staging) / str(index), path)
    print(f"Contribution chart: total={data['total']} through={data['through']} changed_files={len(changed)}")
    return bool(changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--readme", required=True, type=Path)
    parser.add_argument("--user", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        gitdir = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "--absolute-git-dir"], text=True).strip()
        common = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()
        if Path(gitdir).resolve() == Path(common).resolve():
            raise ValueError("Contribution chart updates require a linked publication worktree")
        if args.readme.resolve().parent != args.repo.resolve():
            raise ValueError("The chart README must be inside the publication worktree")
        refresh(args.repo.resolve(), args.readme, args.user, args.dry_run)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f"Contribution chart update aborted: {type(exc).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
