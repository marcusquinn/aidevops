#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Scheduled tracking across every registered property.

Routines never write to repository checkouts: observations and rollups go to
the hub (or local store) copy, which maintainers merge back with `sync`.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import shutil
import subprocess
from pathlib import Path

import keywords_detect as detect
import keywords_hub as hub
import keywords_registry as reg
import keywords_store as store
import keywords_strategy as strategy
import keywords_track as track

SEO_DATA = Path.home() / ".aidevops/.agent-workspace/work/seo-data"


def _repo_paths() -> list[Path]:
    repos_file = Path(os.environ.get("AIDEVOPS_REPOS_FILE") or Path.home() / ".config/aidevops/repos.json")
    if not repos_file.is_file():
        return []
    entries = json.loads(repos_file.read_text(encoding="utf-8")).get("initialized_repos", [])
    return [Path(item["path"]) for item in entries if item.get("path") and item.get("maintenance", True) is not False]


def _has_registry(root: Path) -> bool:
    if (root / reg.STRATEGY_FILE).is_file():
        return True
    prop = _safe_property(root) if root.is_dir() else ""
    return bool(prop) and (hub.data_root() / prop).is_dir()


def registered_roots() -> list[Path]:
    return [root for root in _repo_paths() if _has_registry(root)]


def _safe_property(root: Path) -> str:
    try:
        return hub.property_id(root)
    except ValueError:
        return ""


def _context(root: Path) -> tuple[str, dict, dict, Path]:
    """Property id, front matter and registry, preferring the shared copy."""
    prop = hub.property_id(root)
    pdir = hub.property_dir(prop)
    shared = pdir / "keywords.md"
    front = strategy.parse_front_matter(shared.read_text(encoding="utf-8")) if shared.is_file() else strategy.load(root)
    source = pdir if (pdir / "keywords").is_dir() else root / "context"
    registry = {name: reg.load_table(source / "keywords" / f"{name}.toon", name) for name in reg.TABLES}
    return prop, front, registry, pdir


EXPORT_DAYS = 28
EXPORT_TIMEOUT = 300


def _refresh_one(helper: Path, source: str, domain: str) -> str:
    """Run one exporter; drop any partial file it left behind on failure."""
    folder = SEO_DATA / domain
    before = ({path: path.stat().st_mtime_ns for path in folder.glob(f"{source}-*.toon")}
              if folder.is_dir() else {})
    try:
        result = subprocess.run([str(helper), source, domain, "--days", str(EXPORT_DAYS)], timeout=EXPORT_TIMEOUT,
                                check=False, capture_output=True, text=True)
        code, reason = result.returncode, "no data or credentials"
    except subprocess.TimeoutExpired:
        code, reason = 1, "timeout"
    except OSError:
        code, reason = 1, "helper unavailable"
    changed = ({path for path in folder.glob(f"{source}-*.toon")
                if path.stat().st_mtime_ns != before.get(path)} if folder.is_dir() else set())
    if code == 0 and changed:
        return "refreshed"
    if code != 0:
        for path in changed:
            path.unlink(missing_ok=True)
    return f"skipped:{reason}"


def _refresh_exports(domains: list[str]) -> dict[str, str]:
    """Export fresh GSC/Bing data per domain; never raises, never prints credentials."""
    helper = Path(__file__).parent / "seo-export-helper.sh"
    if os.environ.get("AIDEVOPS_KEYWORDS_OFFLINE") or not helper.is_file():
        return {}
    return {f"{source}:{domain}": _refresh_one(helper, source, domain)
            for domain in domains for source in ("gsc", "bing")}


def _latest_exports(domains: list[str], since: float) -> list[Path]:
    files = []
    for domain in domains:
        for source in ("gsc", "bing"):
            candidates = sorted((SEO_DATA / domain).glob(f"{source}-*.toon"), key=lambda path: path.stat().st_mtime)
            if candidates and candidates[-1].stat().st_mtime > since:
                files.append(candidates[-1])
    return files


def _free_sources(root: Path, prop: str, front: dict, registry: dict) -> dict[str, int | str]:
    surfaces = strategy.as_list(front.get("surfaces"))
    counts: dict[str, int | str] = {}
    slug = detect.github_slug(root)
    if "github" in surfaces and slug and shutil.which("gh"):
        rows = track.github(registry, slug, surfaces)
        counts["github"] = len(rows)
        store.write_observations(prop, rows, "github")
    package = detect.npm_package(root)
    if "npm" in surfaces and package:
        rows = track.npm(registry, package, surfaces)
        counts["npm"] = len(rows)
        store.write_observations(prop, rows, "npm")
    marker = hub.store_dir() / "state" / f"{prop}.exports"
    since = marker.stat().st_mtime if marker.is_file() else 0.0
    domains = strategy.as_list(front.get("domains"))
    counts.update(_refresh_exports(domains))
    for path in _latest_exports(domains, since):
        matched, _unmatched = track.from_export(registry, path)
        counts[path.name] = len(matched)
        store.write_observations(prop, matched, path.name.split("-", 1)[0])
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()
    return counts


def _paid_due(prop: str) -> bool:
    _total, rows = store.month_spend(prop)
    return not any(row.get("provider") == "dataforseo" for row in rows)


def _paid_sources(prop: str, front: dict, registry: dict, pdir: Path, estimate: float) -> dict[str, str]:
    results: dict[str, str] = {}
    if _paid_due(prop) and os.environ.get("DATAFORSEO_USERNAME"):
        for domain in strategy.as_list(front.get("domains")):
            rows, message = track.dataforseo(registry, prop, front, domain, estimate)
            store.write_observations(prop, rows, "dataforseo")
            results[f"dataforseo:{domain}"] = message
    brands = [row["name"] for row in registry["entities"] if row.get("role") == "self"]
    for capture in sorted((pdir / "captures").glob("*.json")):
        if brands:
            rows = track.ai_captures(registry, json.loads(capture.read_text(encoding="utf-8")), brands,
                                     strategy.as_list(front.get("domains")))
            store.write_observations(prop, rows, "ai")
            results[capture.name] = f"{len(rows)} observations"
            done = pdir / "captures" / "imported" / capture.name
            done.parent.mkdir(parents=True, exist_ok=True)
            capture.replace(done)
    return results


def run(paid: bool, estimate: float) -> list[dict]:
    """Track every registered property; returns a per-property summary."""
    hub.pull()
    summary = []
    for root in registered_roots():
        prop, front, registry, pdir = _context(root)
        entry: dict = {"property": prop, "free": _free_sources(root, prop, front, registry)}
        if paid:
            entry["paid"] = _paid_sources(prop, front, registry, pdir, estimate)
        entry["rollup"] = store.rollup(prop, registry)
        for name, rows in registry.items():
            reg.save_table(pdir / "keywords" / f"{name}.toon", name, rows)
        summary.append(entry)
    hub.publish(f"keywords: routine {_dt.date.today().isoformat()}")
    store.build_index()
    return summary
