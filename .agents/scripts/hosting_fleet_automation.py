#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository automation state for fleet moves: snapshot, pause and restore.

Flags are changed only through the supported CLI (`aidevops repos maintenance`
and `aidevops repos pulse`), never by editing repos.json, and are read back
from the registry as proof. Snapshots are owner-private (0600).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_inventory import FleetError  # noqa: E402
from hosting_fleet_steps import registration, run_long  # noqa: E402
from repo_layout_migrate import atomic_write, canonical_bytes, expand_path, load_json  # noqa: E402

FINISHED = {"restored", "restored-after-unmoved-failure"}


def aidevops_cli() -> Path:
    """The orchestrator beside this tree, so the CLI and its modules match."""
    for candidate in (SCRIPT_DIR.parent / "aidevops.sh", SCRIPT_DIR.parent.parent / "aidevops.sh"):
        if candidate.is_file():
            return candidate
    raise FleetError("aidevops.sh not found beside this scripts directory")


def automation_flags(repos_json: Path, slug: str) -> dict[str, bool]:
    """Effective maintenance/Pulse flags of one exactly registered repository."""
    entry = registration(repos_json, slug)
    if not entry:
        raise FleetError(f"Expected exactly one registration for {slug}")
    return {"maintenance": entry.get("maintenance") is not False, "pulse": entry.get("pulse") is True}


def save_snapshot(path: Path, snapshot: dict[str, Any]) -> None:
    """Persist the owner-private (0600) snapshot atomically."""
    atomic_write(path, canonical_bytes(snapshot))


def assert_no_unfinished(state_dir: Path, slugs: list[str]) -> None:
    """Refuse while an unfinished snapshot covers any of these repositories."""
    for path in sorted(state_dir.glob("move-automation-*.json")):
        snapshot = load_json(path)
        covered = set(snapshot.get("flags", {})) | {move["slug"] for move in snapshot.get("moves", [])}
        if snapshot.get("status") not in FINISHED and covered & set(slugs):
            raise FleetError(f"Unfinished move snapshot covers these repositories: {path}; "
                             "finish the native move, then run fleet move --restore with it")


def cli(*arguments: str, repos_json: Path) -> tuple[bool, str]:
    """Run one supported `aidevops repos` automation command."""
    return run_long(["bash", str(aidevops_cli()), "repos", *arguments], cwd=Path.home(),
                    env={"AIDEVOPS_REPOS_CONFIG": str(repos_json)})


def pause(slugs: list[str], repos_json: Path) -> None:
    """Pause maintenance (which also disables Pulse) for every repository."""
    for slug in slugs:
        ok, detail = cli("maintenance", "off", slug, repos_json=repos_json)
        if not ok:
            raise FleetError(f"Could not pause {slug}: {detail}")


def restoration_target(snapshot: dict[str, Any], repos_json: Path, slug: str) -> str:
    """Select only the original registration or a confirmed, path-bound transfer."""
    for move in snapshot.get("moves", []):
        if move.get("old_slug", move["slug"]).lower() != slug.lower():
            continue
        paths = {expand_path(move["source"]), expand_path(move["destination"])}
        original = registration(repos_json, slug)
        if original.get("path") and expand_path(original["path"]) in paths:
            return slug
        target = registration(repos_json, move["slug"])
        if (move["slug"] in snapshot.get("transferred", []) and target.get("path")
                and expand_path(target["path"]) in paths):
            return move["slug"]
        raise FleetError(f"Cannot identify the move registration for {slug}; automation stays paused")
    return slug


def restore_flags(snapshot: dict[str, Any], repos_json: Path) -> dict[str, Any]:
    """Restore maintenance, then Pulse, and read both back as proof."""
    proof = {}
    for slug, wanted in snapshot["flags"].items():
        target = restoration_target(snapshot, repos_json, slug)
        if wanted["maintenance"]:
            cli("maintenance", "on", target, repos_json=repos_json)
            if wanted["pulse"]:
                cli("pulse", "on", target, repos_json=repos_json)
        proof[slug] = automation_flags(repos_json, target)
    return proof
