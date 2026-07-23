#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fetch repository stargazer timestamps and render a deterministic static SVG."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import math
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


WIDTH = 1000
HEIGHT = 520
MARGIN_LEFT = 78
MARGIN_RIGHT = 34
MARGIN_TOP = 92
MARGIN_BOTTOM = 66
REPO_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def parse_timestamp(value: str) -> dt.datetime:
    """Parse one GitHub ISO-8601 timestamp as an aware UTC datetime."""
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"invalid stargazer timestamp: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def extract_timestamps(payload: Any) -> list[str]:
    """Extract only timestamps from a fixture list or paginated GitHub payload."""
    timestamps: list[str] = []

    def visit(item: Any) -> None:
        if isinstance(item, str):
            timestamps.append(item)
            return
        if isinstance(item, dict):
            value = item.get("starred_at")
            if isinstance(value, str):
                timestamps.append(value)
            return
        if isinstance(item, list):
            for child in item:
                visit(child)

    visit(payload)
    return timestamps


def fetch_timestamps(repo: str) -> list[str]:
    """Fetch all stargazer pages with gh without persisting account details."""
    if not REPO_PATTERN.fullmatch(repo):
        raise ValueError(f"invalid repository slug: {repo!r}")
    command = [
        "gh",
        "api",
        "--paginate",
        "--slurp",
        "-H",
        "Accept: application/vnd.github.star+json",
        f"repos/{repo}/stargazers?per_page=100",
    ]
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError("gh CLI is required to fetch star history") from exc
    except subprocess.CalledProcessError as exc:
        message = exc.stderr.strip() or "GitHub API request failed"
        raise RuntimeError(message) from exc
    return extract_timestamps(json.loads(completed.stdout))


def cumulative_points(timestamps: list[str]) -> list[tuple[dt.date, int]]:
    """Convert timestamps into sorted end-of-day cumulative counts."""
    counts = Counter(parse_timestamp(value).date() for value in timestamps)
    total = 0
    points: list[tuple[dt.date, int]] = []
    for day in sorted(counts):
        total += counts[day]
        points.append((day, total))
    return points


def nice_ceiling(value: int) -> int:
    """Round a positive count to a readable chart-axis ceiling."""
    if value <= 5:
        return 5
    magnitude = 10 ** int(math.floor(math.log10(value)))
    for multiplier in (1, 2, 4, 5, 10):
        candidate = multiplier * magnitude
        if candidate >= value:
            return candidate
    return 10 * magnitude


def scale_x(day: dt.date, first: dt.date, last: dt.date) -> float:
    span = max((last - first).days, 1)
    return MARGIN_LEFT + ((day - first).days / span) * (WIDTH - MARGIN_LEFT - MARGIN_RIGHT)


def scale_y(value: int, maximum: int) -> float:
    plot_height = HEIGHT - MARGIN_TOP - MARGIN_BOTTOM
    return MARGIN_TOP + (1 - value / maximum) * plot_height


def date_label(day: dt.date) -> str:
    return day.strftime("%b %Y")


def render_empty(repo: str) -> str:
    safe_repo = html.escape(repo)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="title desc">
  <title id="title">{safe_repo} star history</title>
  <desc id="desc">No stargazer history is currently available.</desc>
  <style>
    .background {{ fill: #ffffff; }} .title {{ fill: #1f2328; }} .muted {{ fill: #59636e; }}
    @media (prefers-color-scheme: dark) {{ .background {{ fill: #0d1117; }} .title {{ fill: #f0f6fc; }} .muted {{ fill: #8b949e; }} }}
  </style>
  <rect class="background" width="{WIDTH}" height="{HEIGHT}" rx="12"/>
  <text class="title" x="{WIDTH / 2:.0f}" y="230" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="26" font-weight="600">{safe_repo}</text>
  <text class="muted" x="{WIDTH / 2:.0f}" y="272" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="16">No star history available</text>
</svg>
"""


def render_svg(repo: str, timestamps: list[str]) -> str:
    """Render a stable, responsive light/dark SVG from stargazer timestamps."""
    if not REPO_PATTERN.fullmatch(repo):
        raise ValueError(f"invalid repository slug: {repo!r}")
    points = cumulative_points(timestamps)
    if not points:
        return render_empty(repo)

    first_day = points[0][0]
    last_day = points[-1][0]
    axis_last = last_day if last_day > first_day else first_day + dt.timedelta(days=1)
    maximum = nice_ceiling(points[-1][1])
    safe_repo = html.escape(repo)
    total = points[-1][1]
    star_label = "star" if total == 1 else "stars"

    path_points = [(scale_x(day, first_day, axis_last), scale_y(count, maximum)) for day, count in points]
    if len(path_points) == 1:
        path_points.append((scale_x(axis_last, first_day, axis_last), path_points[0][1]))
    polyline = " ".join(f"{x:.1f},{y:.1f}" for x, y in path_points)
    area = (
        f"{MARGIN_LEFT},{HEIGHT - MARGIN_BOTTOM} {polyline} "
        f"{WIDTH - MARGIN_RIGHT},{HEIGHT - MARGIN_BOTTOM}"
    )

    y_grid: list[str] = []
    for index in range(5):
        value = round(maximum * index / 4)
        y = scale_y(value, maximum)
        y_grid.append(
            f'  <line class="grid" x1="{MARGIN_LEFT}" y1="{y:.1f}" x2="{WIDTH - MARGIN_RIGHT}" y2="{y:.1f}"/>'
        )
        y_grid.append(
            f'  <text class="axis" x="{MARGIN_LEFT - 14}" y="{y + 5:.1f}" text-anchor="end">{value}</text>'
        )

    x_grid: list[str] = []
    span_days = max((axis_last - first_day).days, 1)
    seen_labels: set[str] = set()
    for index in range(6):
        day = first_day + dt.timedelta(days=round(span_days * index / 5))
        label = date_label(day)
        if label in seen_labels:
            continue
        seen_labels.add(label)
        x = scale_x(day, first_day, axis_last)
        x_grid.append(
            f'  <text class="axis" x="{x:.1f}" y="{HEIGHT - MARGIN_BOTTOM + 32}" text-anchor="middle">{label}</text>'
        )

    description = html.escape(
        f"{repo} grew from its first recorded star on {first_day.isoformat()} "
        f"to {total} {star_label} on {last_day.isoformat()}."
    )
    subtitle = html.escape(
        f"{total} {star_label} · {first_day.strftime('%d %b %Y')} – {last_day.strftime('%d %b %Y')}"
    )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="title desc">
  <title id="title">{safe_repo} star history</title>
  <desc id="desc">{description}</desc>
  <style>
    .background {{ fill: #ffffff; }} .heading {{ fill: #1f2328; }} .axis {{ fill: #59636e; font: 12px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; }}
    .grid {{ stroke: #d8dee4; stroke-width: 1; }} .area {{ fill: #58a6ff; opacity: .12; }} .line {{ fill: none; stroke: #238636; stroke-width: 4; stroke-linecap: round; stroke-linejoin: round; }}
    .point {{ fill: #238636; stroke: #ffffff; stroke-width: 3; }}
    @media (prefers-color-scheme: dark) {{ .background {{ fill: #0d1117; }} .heading {{ fill: #f0f6fc; }} .axis {{ fill: #8b949e; }} .grid {{ stroke: #30363d; }} .area {{ fill: #58a6ff; opacity: .16; }} .line {{ stroke: #2ea043; }} .point {{ fill: #2ea043; stroke: #0d1117; }} }}
  </style>
  <rect class="background" width="{WIDTH}" height="{HEIGHT}" rx="12"/>
  <text class="heading" x="{MARGIN_LEFT}" y="42" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif" font-size="24" font-weight="600">{safe_repo}</text>
  <text class="axis" x="{MARGIN_LEFT}" y="68">{subtitle}</text>
{chr(10).join(y_grid)}
{chr(10).join(x_grid)}
  <polygon class="area" points="{area}"/>
  <polyline class="line" points="{polyline}"/>
  <circle class="point" cx="{path_points[-1][0]:.1f}" cy="{path_points[-1][1]:.1f}" r="6"/>
</svg>
"""


def write_if_changed(path: Path, content: str) -> bool:
    """Write text only when content differs, preserving no-op workflow runs."""
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a static repository star-history SVG")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("fetch", "render", "seed"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--repo", required=True, help="repository slug (owner/name)")
        subparser.add_argument("--output", required=True, help="SVG output path")
        if command == "render":
            subparser.add_argument("--input", required=True, help="JSON timestamp fixture path")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "fetch":
            timestamps = fetch_timestamps(args.repo)
        elif args.command == "render":
            payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
            timestamps = extract_timestamps(payload)
        else:
            timestamps = []
        changed = write_if_changed(Path(args.output), render_svg(args.repo, timestamps))
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"star-history: {exc}", file=sys.stderr)
        return 1
    state = "updated" if changed else "unchanged"
    star_label = "star" if len(timestamps) == 1 else "stars"
    print(f"star-history: {state} {args.output} ({len(timestamps)} {star_label})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
