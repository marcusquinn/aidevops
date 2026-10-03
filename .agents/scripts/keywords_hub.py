#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Team hub location, git transport and registry sync for keyword data.

The hub is a private Git repository shared by maintainers. Its slug and path
live only in local config/environment, never in repository files.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import keywords_registry as reg
import keywords_strategy as strategy


def store_dir() -> Path:
    default = Path.home() / ".aidevops/.agent-workspace/keywords"
    return Path(os.environ.get("AIDEVOPS_KEYWORDS_STORE_DIR") or default)


def hub_slug() -> str:
    return os.environ.get("AIDEVOPS_KEYWORDS_HUB_SLUG", "").strip()


def hub_dir() -> Path | None:
    """Return the hub checkout path, or None when no hub is configured."""
    explicit = os.environ.get("AIDEVOPS_KEYWORDS_HUB_PATH", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    slug = hub_slug()
    if not slug:
        return None
    return store_dir() / "hub" / slug.replace("/", "__")


def data_root() -> Path:
    """Where property data lives: the hub checkout, or a local-only store."""
    return hub_dir() or store_dir() / "local"


def property_id(root: Path) -> str:
    front = strategy.load(root)
    candidate = str(front.get("property") or "")
    if not candidate:
        remote = _git(Path(root), "remote", "get-url", "origin", check=False).strip()
        match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", remote)
        candidate = match.group(1).replace("/", "__") if match else Path(root).resolve().name
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", candidate).strip("-.")
    if not safe:
        raise ValueError("cannot derive a property id; set `property:` in context/keywords.md")
    return safe


def property_dir(prop: str) -> Path:
    return data_root() / prop


def _git(path: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def ensure_hub() -> Path | None:
    """Clone the hub when configured and missing; returns its path."""
    path = hub_dir()
    if path is None or (path / ".git").exists():
        return path
    slug = hub_slug()
    if not slug:
        raise RuntimeError(f"hub path {path} is not a git checkout and no hub slug is configured")
    path.parent.mkdir(parents=True, exist_ok=True)
    # Clone from the hub's parent: routines may start inside a canonical checkout,
    # where the canonical Git guard blocks clones that inherit that cwd.
    cwd = str(path.parent)
    cloned = shutil.which("gh") and subprocess.run(
        ["gh", "repo", "clone", slug, str(path), "--", "--quiet"],
        capture_output=True, check=False, cwd=cwd).returncode == 0
    if not cloned:
        subprocess.run(["git", "clone", "--quiet", f"https://github.com/{slug}.git", str(path)], check=True, cwd=cwd)
    return path


def pull() -> None:
    path = ensure_hub()
    if path is not None and _git(path, "remote", check=False).strip():
        _git(path, "pull", "--rebase", "--autostash", "--quiet", check=False)


def publish(message: str) -> bool:
    """Commit and push hub changes; retries once after a rebase."""
    path = hub_dir()
    if path is None:
        return False
    _git(path, "add", "-A")
    if not _git(path, "status", "--porcelain").strip():
        return False
    _git(path, "commit", "--quiet", "-m", message)
    if not _git(path, "remote", check=False).strip():
        return True
    if subprocess.run(["git", "-C", str(path), "push", "--quiet"], capture_output=True, check=False).returncode:
        _git(path, "pull", "--rebase", "--quiet")
        _git(path, "push", "--quiet")
    return True


def _pick(local: dict, remote: dict | None) -> tuple[dict, bool]:
    """Return (winning row, conflict flag) for one ID."""
    if remote is None or remote == local:
        return local, False
    local_time, remote_time = local.get("updated", ""), remote.get("updated", "")
    if local_time == remote_time:
        return local, True
    return (local if local_time > remote_time else remote), False


def merge_rows(local: list[dict], remote: list[dict]) -> tuple[list[dict], list[str]]:
    """Union by id; newer `updated` wins; equal timestamps with different content keep local."""
    merged: dict[str, dict] = {row["id"]: row for row in remote}
    conflicts: list[str] = []
    for row in local:
        winner, conflict = _pick(row, merged.get(row["id"]))
        merged[row["id"]] = winner
        conflicts += [row["id"]] if conflict else []
    ordered = [merged.pop(row["id"]) for row in local if row["id"] in merged]
    return ordered + list(merged.values()), conflicts


def _hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""


def _state_path(prop: str) -> Path:
    return store_dir() / "state" / f"{prop}.json"


def _strategy_direction(local_hash: str, remote_hash: str, base: str) -> str:
    """Three-way decision for keywords.md using the last synced hash as base."""
    if local_hash == remote_hash:
        return "unchanged"
    if not local_hash:
        return "pulled"
    if not remote_hash:
        return "pushed"
    if local_hash == base:
        return "pulled"
    return "pushed" if remote_hash == base else "conflict"


def _copy(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def _sync_strategy(root: Path, pdir: Path, prop: str) -> str:
    local, remote = Path(root) / reg.STRATEGY_FILE, pdir / "keywords.md"
    state_file = _state_path(prop)
    base = json.loads(state_file.read_text()).get("strategy_hash", "") if state_file.is_file() else ""
    outcome = _strategy_direction(_hash(local), _hash(remote), base)
    if outcome == "pushed":
        _copy(local, remote)
    elif outcome == "pulled":
        _copy(remote, local)
    elif outcome == "conflict":
        _copy(remote, local.with_name("keywords.md.hub"))
        return "conflict: hub copy written to context/keywords.md.hub; reconcile, then sync again"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps({"strategy_hash": _hash(local)}), encoding="utf-8")
    return outcome


def sync(root: Path, write_local: bool = True) -> dict:
    """Two-way merge of the local registry with the hub/local store copy."""
    root = Path(root)
    prop = property_id(root)
    pull()
    pdir = property_dir(prop)
    report: dict = {"property": prop, "store": str(pdir), "tables": {}, "conflicts": {}}
    report["strategy"] = _sync_strategy(root, pdir, prop)
    for table in reg.TABLES:
        local_rows = reg.load_table(reg.table_path(root, table), table)
        remote_rows = reg.load_table(pdir / "keywords" / f"{table}.toon", table)
        merged, conflicts = merge_rows(local_rows, remote_rows)
        reg.save_table(pdir / "keywords" / f"{table}.toon", table, merged)
        if write_local:
            reg.save_table(reg.table_path(root, table), table, merged)
        report["tables"][table] = len(merged)
        if conflicts:
            report["conflicts"][table] = conflicts
    report["published"] = publish(f"keywords: sync {prop}")
    return report
