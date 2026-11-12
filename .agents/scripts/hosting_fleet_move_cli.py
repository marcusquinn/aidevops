#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""CLI handlers for `fleet move`: preview, apply and restore reporting.

The move mechanics (snapshot, pause, native plan/apply, restore) live in
hosting_fleet_move.py; this module selects the mode and prints results.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_automation import FINISHED, automation_flags  # noqa: E402
from hosting_fleet_inventory import FleetError  # noqa: E402
from hosting_fleet_move import (  # noqa: E402
    MOVE_FAILED_EXIT,
    apply_move,
    finish,
    move_progress,
    select_moves,
)
from repo_layout_migrate import expand_path, load_json  # noqa: E402


def restore_move(path: Path, repos_json: Path) -> dict[str, Any]:
    """Restore a paused snapshot once every move is complete (or none started)."""
    snapshot = load_json(path)
    if snapshot.get("status") in FINISHED:
        raise FleetError(f"Snapshot already finished: {snapshot['status']}")
    progress = move_progress(snapshot["moves"])
    return finish(snapshot, path, repos_json, (progress == "all", f"moves {progress}"))


def preview_move(plan: dict[str, Any], sites: list[str] | None, repos_json: Path) -> dict[str, Any]:
    """Read-only: the selected moves, their current flags and the hash to confirm."""
    moves = select_moves(plan, sites)
    return {"plan_sha256": plan["plan_sha256"], "moves": moves, "sites": sorted(sites or []),
            "flags": {move["old_slug"]: automation_flags(repos_json, move["old_slug"]) for move in moves}}


def print_move(report: dict[str, Any]) -> None:
    """Human summary of a preview or an apply/restore result."""
    for move in report["moves"]:
        flags = report["flags"].get(move.get("old_slug", move["slug"]), {})
        print(f"  {move['slug']}: maintenance={flags.get('maintenance')} pulse={flags.get('pulse')}")
        print(f"    {move['source']} -> {move['destination']}")
    if "status" not in report:
        sites = " ".join(f"--site {site}" for site in report["sites"])
        print(f"Preview only. Apply with: fleet move {sites} --apply --confirm {report['plan_sha256']}")
        return
    print(f"Status: {report['status']} ({report['detail']})")
    print(f"Snapshot: {report['snapshot']}")
    if report["status"] == "paused-after-partial-move":
        print("Automation stays paused. Finish any pending repository transfer "
              "(canonical-recovery-helper.sh follow-transfer) and the native move, then restore:")
        print(f"  {report.get('native_resume') or 'aidevops repos migrate-layout status --receipt <id>'}")
        print(f"  hostinger-helper.sh fleet move --restore {report['snapshot']}")


def run_move(args: Any, load_plan: Callable[[], dict[str, Any]], state_dir: Path) -> int:
    """CLI handler: preview, apply against the confirmed hash, or restore a snapshot."""
    repos_json = expand_path(args.repos_json)
    if args.restore:
        report = restore_move(expand_path(args.restore), repos_json)
    elif args.apply:
        if not args.confirm:
            raise FleetError("--apply requires --confirm with the fleet plan hash from the preview")
        report = apply_move(load_plan(), args.site, args.confirm, repos_json, state_dir)
    else:
        report = preview_move(load_plan(), args.site, repos_json)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_move(report)
    failed = (args.apply or args.restore) and not report["ok"]
    return MOVE_FAILED_EXIT if failed else 0
