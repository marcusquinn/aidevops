#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""What uses a credential? Local, read-only dependents search (GH#34719).

Searches registered repos and their linked worktrees, custom agents, local
aidevops configs, scheduler definitions and the user crontab for a secret
name and its aliases. Reads no secret values, makes no network calls, and
reports `complete: false` whenever coverage is unproven (dynamic name
construction, timeouts, truncation or unreadable sources), so a result
never claims "unused" without evidence.
"""

from __future__ import annotations

import json
import subprocess  # nosec B404 -- exception classes only; commands run via credential_inventory_scan.run_tool
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import credential_inventory_scan as scan

GREP_TIMEOUT = 30
MAX_WORKERS = 8
CONFIG_SUFFIXES = {".json", ".conf", ".toml", ".yaml", ".yml"}
REGISTRY_FILE = "credential-inventory.json"


def registered_repos(home: Path) -> list[tuple[str, Path]]:
    """(label, path) for each existing repo in repos.json."""
    try:
        data = json.loads((home / ".config" / "aidevops" / "repos.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    entries = data.get("initialized_repos", []) if isinstance(data, dict) else []
    repos = []
    for entry in entries if isinstance(entries, list) else []:
        path = Path(str((entry or {}).get("path", ""))).expanduser()
        if str(path) != "." and path.is_dir():
            repos.append((str(entry.get("slug") or path.name), path))
    return repos


def worktrees(repo: Path) -> list[Path]:
    """Existing worktree paths (main checkout included) for a repo."""
    try:
        result = scan.run_tool("git", ["-C", str(repo), "worktree", "list", "--porcelain"], GREP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return [repo]
    paths = [Path(line[9:]) for line in result.stdout.splitlines() if line.startswith("worktree ")]
    return [path for path in paths if path.is_dir()] or [repo]


def local_files(home: Path) -> dict[str, list[Path]]:
    """Config and scheduler files to scan, grouped by source."""
    config_dir = home / ".config" / "aidevops"
    configs = sorted(
        path for path in config_dir.glob("*")
        if path.is_file() and path.suffix in CONFIG_SUFFIXES and path.name != REGISTRY_FILE
    ) if config_dir.is_dir() else []
    schedulers = sorted((home / "Library" / "LaunchAgents").glob("*.plist"))
    systemd = home / ".config" / "systemd" / "user"
    schedulers += sorted(path for path in systemd.glob("*") if path.suffix in {".service", ".timer"})
    return {"config": configs, "scheduler": schedulers}


def crontab_hits(needles: scan.Needles) -> tuple[list[dict], str | None]:
    """Scan `crontab -l`; no crontab is an empty result, not a gap."""
    try:
        result = scan.run_tool("crontab", ["-l"], 10)
    except FileNotFoundError:
        return [], None
    except (OSError, subprocess.SubprocessError):
        return [], "crontab unreadable"
    if result.returncode != 0:
        return [], None
    return [{"path": "crontab", **hit} for hit in scan.scan_lines(result.stdout.splitlines(), needles)], None


class Report:
    """Accumulates hits, skipped sources and coverage counts."""

    def __init__(self, names: list[str]) -> None:
        self.names = names
        self.hits: list[dict] = []
        self.skipped: list[dict] = []
        self.scanned: dict[str, int] = {}

    def add(self, source: str, location: str, hits: list[dict], reason: str | None = None) -> None:
        self.hits += [{"source": source, "location": location, **hit} for hit in hits]
        if reason:
            self.skipped.append({"source": source, "location": location, "reason": reason})
        self.scanned[source] = self.scanned.get(source, 0) + 1

    def result(self) -> dict[str, Any]:
        literal = [hit for hit in self.hits if hit["kind"] == "literal"]
        dynamic = [hit for hit in self.hits if hit["kind"] == "possible-dynamic"]
        return {
            "name": self.names[0],
            "aliases": self.names[1:],
            "literal": literal,
            "possible_dynamic": dynamic,
            "skipped": self.skipped,
            "scanned": self.scanned,
            "complete": not dynamic and not self.skipped,
        }


def scan_repos(report: Report, home: Path, needles: scan.Needles) -> None:
    """git grep every worktree of every registered repo, in parallel."""
    targets = [(label, tree) for label, repo in registered_repos(home) for tree in worktrees(repo)]
    targets = list({str(tree): (label, tree) for label, tree in targets}.values())
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        results = pool.map(lambda target: scan.grep_worktree(target[1], needles, GREP_TIMEOUT), targets)
        for (label, tree), (hits, reason) in zip(targets, results):
            report.add("repo", str(tree), [{"repo": label, **hit} for hit in hits], reason)


def scan_local(report: Report, home: Path, needles: scan.Needles) -> None:
    """Custom agents, aidevops configs, schedulers and crontab."""
    custom, capped = scan.tree_files(home / ".aidevops" / "agents" / "custom")
    groups = {"custom-agents": custom, **local_files(home)}
    for source, paths in groups.items():
        hits, skipped = scan.scan_files(paths, needles)
        report.add(source, source, hits, "file limit reached" if source == "custom-agents" and capped else None)
        report.scanned[source] = len(paths)
        for path in skipped:
            report.skipped.append({"source": source, "location": path, "reason": "unreadable or too large"})
    hits, reason = crontab_hits(needles)
    report.add("crontab", "crontab", hits, reason)


def find_dependents(names: list[str], home: Path | None = None) -> dict[str, Any]:
    """Search all local sources for `names` (canonical first, then aliases)."""
    home = home or Path.home()
    needles = scan.build_needles(names)
    report = Report(names)
    scan_repos(report, home, needles)
    scan_local(report, home, needles)
    return report.result()


def render(result: dict[str, Any]) -> str:
    """Human-readable report; never states 'unused' when incomplete."""
    aliases = f" (aliases: {', '.join(result['aliases'])})" if result["aliases"] else ""
    lines = [f"Dependents of {result['name']}{aliases}"]
    for label, key in (("literal", "literal"), ("possible-dynamic", "possible_dynamic")):
        for hit in result[key]:
            lines.append(f"  {label:16} {hit['location']}  {hit['path']}:{hit['line']}  [{hit['matched']}]")
    for skip in result["skipped"]:
        lines.append(f"  skipped          {skip['location']}  ({skip['reason']})")
    scanned = ", ".join(f"{source} {count}" for source, count in sorted(result["scanned"].items()))
    lines.append(f"Scanned: {scanned}")
    if not result["complete"]:
        lines.append("INCOMPLETE: dynamic name construction or skipped sources; do not treat this name as unused.")
    elif not result["literal"]:
        lines.append("No references found in the scanned sources.")
    return "\n".join(lines)
