#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate local repository metrics for README badges and app about pages.

The scanner is intentionally dependency-light: Python stdlib plus git when the
target is a git repository. It counts tracked and unignored source files,
detects language mix by extension/basename, extracts dependency counts from
common manifests/lockfiles, and writes stable local artifacts:

  docs/metrics/repo-metrics.json
  docs/metrics/repo-metrics.md
  docs/metrics/badges/{loc,languages,dependencies}.svg

It can also write legacy .github/badges/loc-total.svg and
.github/badges/loc-languages.svg for existing aidevops-managed README blocks.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys
from pathlib import Path
from typing import Any

from repo_metrics_dependencies import collect_dependencies
from repo_metrics_files import list_repo_files
from repo_metrics_git import git_remote_slug, repo_root
from repo_metrics_languages import collect_languages
from repo_metrics_render import (
    human_count,
    render_flat_badge,
    render_languages_svg,
    render_markdown,
    write_text,
)


TOOL_VERSION = "1.0.0"

DEFAULT_EXCLUDES = (
    ".git",
    ".hg",
    ".svn",
    "__aidevops",
    "node_modules",
    "vendor",
    "dist",
    "build",
    ".next",
    ".nuxt",
    ".cache",
    ".venv",
    "venv",
    "env",
    "target",
    "coverage",
    "docs/metrics",
    ".github/badges",
)


def build_metrics(root: Path, paths: list[Path], excludes: list[str], top_n: int) -> dict[str, Any]:
    files = list_repo_files(root, paths, excludes)
    languages, totals = collect_languages(root, files)
    dependencies = collect_dependencies(root, files)
    generated_at = _dt.datetime.now(tz=_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    summary = {
        **totals,
        "dependencies": dependencies["total"],
    }
    slug = git_remote_slug(root)
    repo_name = slug.split("/", 1)[1] if "/" in slug else root.name
    return {
        "schema": "aidevops.repo-metrics.v1",
        "schema_version": 1,
        "generated_at": generated_at,
        "tool": {"name": "aidevops repo-metrics", "version": TOOL_VERSION},
        "repo": {"name": repo_name, "slug": slug},
        "summary": summary,
        "languages": languages,
        "dependencies": dependencies,
        "refresh": {
            "default_policy": "weekly scheduled refresh plus manual runs; skip generated outputs younger than 24h in managed workflows",
            "cost_profile": "fast local git/unignored-file scan; no network by default",
            "top_languages": top_n,
        },
    }


def loc_summary(metrics: dict[str, Any], top_n: int) -> dict[str, Any]:
    summary = metrics["summary"]
    languages = metrics["languages"]
    return {
        "total": {
            "code": summary["code"],
            "comments": summary["comments"],
            "blanks": summary["blanks"],
            "files": summary["source_files"],
        },
        "languages": [
            {"name": item["name"], "code": item["code"], "files": item["files"]} for item in languages
        ],
        "top": [
            {"name": item["name"], "code": item["code"], "files": item["files"]}
            for item in languages[:top_n]
        ],
    }


def resolve_output(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def outputs_fresh(json_path: Path, badge_dir: Path, legacy_badge_dir: Path | None, max_age_hours: float | None) -> bool:
    if max_age_hours is None:
        return False
    required = [json_path, json_path.with_suffix(".md"), badge_dir / "loc.svg", badge_dir / "languages.svg", badge_dir / "dependencies.svg"]
    if legacy_badge_dir is not None:
        required.extend([legacy_badge_dir / "loc-total.svg", legacy_badge_dir / "loc-languages.svg"])
    if any(not item.exists() for item in required):
        return False
    age_seconds = _dt.datetime.now().timestamp() - json_path.stat().st_mtime
    return age_seconds < max_age_hours * 3600


def write_outputs(metrics: dict[str, Any], output_dir: Path, badge_dir: Path, legacy_badge_dir: Path | None, top_n: int) -> None:
    json_path = output_dir / "repo-metrics.json"
    md_path = output_dir / "repo-metrics.md"
    badge_dir.mkdir(parents=True, exist_ok=True)
    write_text(json_path, json.dumps(metrics, indent=2, sort_keys=False) + "\n")
    write_text(md_path, render_markdown(metrics))

    total_code = int(metrics["summary"]["code"])
    deps = metrics["dependencies"]
    write_text(badge_dir / "loc.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
    write_text(badge_dir / "languages.svg", render_languages_svg(metrics["languages"], top_n))
    dep_value = f"{int(deps['direct'])} direct" if int(deps["total"]) == int(deps["direct"]) else f"{int(deps['direct'])}/{int(deps['total'])}"
    write_text(badge_dir / "dependencies.svg", render_flat_badge("dependencies", dep_value, "#4c1"))

    write_text(badge_dir / "loc-total.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
    write_text(badge_dir / "loc-languages.svg", render_languages_svg(metrics["languages"], top_n))
    if legacy_badge_dir is not None:
        legacy_badge_dir.mkdir(parents=True, exist_ok=True)
        write_text(legacy_badge_dir / "loc-total.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
        write_text(legacy_badge_dir / "loc-languages.svg", render_languages_svg(metrics["languages"], top_n))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate local repository metrics and README badge assets")
    parser.add_argument("paths", nargs="*", default=["."], help="repository or sub-paths to scan")
    parser.add_argument("--output-dir", default="docs/metrics", help="directory for repo-metrics.json/md")
    parser.add_argument("--badge-dir", default="", help="directory for SVG badges (default: OUTPUT_DIR/badges)")
    parser.add_argument("--legacy-badge-dir", default="", help="optional legacy .github/badges output directory")
    parser.add_argument("--top", type=int, default=6, help="top-N languages for stacked language badge")
    parser.add_argument("--exclude", action="append", default=[], help="extra path or glob pattern to exclude")
    parser.add_argument("--json-only", action="store_true", help="print full metrics JSON without writing files")
    parser.add_argument("--loc-summary-json", action="store_true", help="print legacy LOC summary JSON without writing files")
    parser.add_argument("--skip-if-fresh-hours", type=float, default=None, help="skip writes when outputs are newer than this age")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    scan_paths = [Path(item).expanduser() for item in args.paths]
    first_path = scan_paths[0] if scan_paths else Path(".")
    root = repo_root(first_path.resolve())
    excludes = list(DEFAULT_EXCLUDES) + list(args.exclude or [])
    output_dir = resolve_output(root, args.output_dir)
    badge_dir = resolve_output(root, args.badge_dir) if args.badge_dir else output_dir / "badges"
    legacy_badge_dir = resolve_output(root, args.legacy_badge_dir) if args.legacy_badge_dir else None
    json_path = output_dir / "repo-metrics.json"

    if not args.json_only and not args.loc_summary_json and outputs_fresh(json_path, badge_dir, legacy_badge_dir, args.skip_if_fresh_hours):
        print(f"repo metrics fresh: {json_path}", file=sys.stderr)
        return 0

    metrics = build_metrics(root, scan_paths, excludes, max(args.top, 1))
    if args.loc_summary_json:
        print(json.dumps(loc_summary(metrics, max(args.top, 1)), indent=2, sort_keys=False))
        return 0
    if args.json_only:
        print(json.dumps(metrics, indent=2, sort_keys=False))
        return 0

    write_outputs(metrics, output_dir, badge_dir, legacy_badge_dir, max(args.top, 1))
    print(f"repo metrics written: {json_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
