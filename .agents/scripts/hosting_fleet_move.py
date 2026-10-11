#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fleet layout moves: native migrate-layout wrapped in an automation snapshot.

Preview (read-only) selects the named `misplaced` fleet sites and prints their
moves, current maintenance/Pulse flags and the fleet plan hash to confirm.

Apply requires that exact hash, then: snapshot each repository's flags once,
pause it with `aidevops repos maintenance off` (which also disables Pulse),
write a scoped native `migrate-layout plan --source ... --include-registered-paths`
(after pausing, because the native plan records repos.json as a consumer
before-state), refuse unless it matches the fleet moves, run native apply, and
restore both flags by slug with `aidevops repos maintenance on` and
`aidevops repos pulse on` (maintenance on alone leaves Pulse off).

A refusal or failure before any repository moved restores automation. A partial
move stays paused: finish it with the printed native resume command, then
`fleet move --restore SNAPSHOT`, which refuses unless every move is complete or
none started. A new apply is refused while an unfinished snapshot covers any
of the same repositories, so paused flags are never snapshotted as originals.
"""

from __future__ import annotations

import json
import subprocess  # nosec B404
import sys
import time
from pathlib import Path
from typing import Any, Callable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from hosting_fleet_automation import (  # noqa: E402
    FINISHED,
    assert_no_unfinished,
    automation_flags,
    pause,
    restore_flags,
    save_snapshot,
)
from hosting_fleet_inventory import FleetError  # noqa: E402
from hosting_fleet_steps import run_long  # noqa: E402
from repo_layout_migrate import canonical_bytes, expand_path, load_json, private_directory, sha256_bytes  # noqa: E402

MIGRATE_HELPER = SCRIPT_DIR / "repo-layout-migrate-helper.sh"
MOVE_FAILED_EXIT = 6


def select_moves(plan: dict[str, Any], sites: list[str] | None) -> list[dict[str, str]]:
    """Exact misplaced repositories for the named sites; sites are mandatory."""
    wanted = {site.strip().lower() for site in sites or []}
    if not wanted:
        raise FleetError("Name every site to move with --site; whole-fleet moves are not allowed")
    by_domain = {item["domain"]: item for item in plan["sites"]}
    unknown = sorted(wanted - by_domain.keys())
    if unknown:
        raise FleetError(f"Not in this fleet plan: {', '.join(unknown)}")
    not_misplaced = sorted(domain for domain in wanted if by_domain[domain]["state"] != "misplaced")
    if not_misplaced:
        raise FleetError(f"Only misplaced sites can move; not misplaced: {', '.join(not_misplaced)}")
    moves = {}
    for domain in sorted(wanted):
        item = by_domain[domain]
        moves[item["expected_slug"]] = {"slug": item["expected_slug"],
                                        "source": str(expand_path(item["registered_path"])),
                                        "destination": str(expand_path(item["expected_path"]))}
    return sorted(moves.values(), key=lambda move: move["slug"])


def native_moves(native: dict[str, Any]) -> list[dict[str, str]]:
    """Moves recorded in a native layout plan, keyed by remote slug."""
    return sorted(({"slug": f"{repo['remote']['owner']}/{repo['remote']['repository']}",
                    "source": repo["source"], "destination": repo["destination"]}
                   for repo in native.get("repositories", [])), key=lambda move: move["slug"])


def write_native_plan(workspace: str, moves: list[dict[str, str]], output: Path) -> dict[str, Any]:
    """Run the scoped native plan and require it to match the fleet moves exactly."""
    command = ["bash", str(MIGRATE_HELPER), "plan", "--workspace", workspace,
               "--include-registered-paths", "--output", str(output)]
    for move in moves:
        command += ["--source", move["source"]]
    ok, detail = run_long(command, cwd=expand_path(workspace))
    if not ok:
        raise FleetError(f"Native layout plan refused: {detail}")
    native = load_json(output)
    if native.get("exclusions") or native_moves(native) != moves:
        raise FleetError("Native layout plan does not match the selected fleet moves")
    return native


def move_progress(moves: list[dict[str, str]]) -> str:
    """none, all or partial, from physical source/destination presence."""
    done = [not Path(move["source"]).exists() and Path(move["destination"]).exists() for move in moves]
    untouched = [Path(move["source"]).exists() and not Path(move["destination"]).exists() for move in moves]
    return "all" if all(done) else "none" if all(untouched) else "partial"


def finish(snapshot: dict[str, Any], path: Path, repos_json: Path, outcome: tuple[bool, str]) -> dict[str, Any]:
    """Restore automation when every move or none happened; otherwise stay paused."""
    ok, detail = outcome
    progress = move_progress(snapshot["moves"])
    if progress == "partial" or (ok and progress != "all"):
        snapshot["status"] = "paused-after-partial-move"
    else:
        snapshot["proof"] = restore_flags(snapshot, repos_json)
        restored = snapshot["proof"] == snapshot["flags"]
        moved = "restored" if progress == "all" else "restored-after-unmoved-failure"
        snapshot["status"] = moved if restored else "restore-mismatch"
    save_snapshot(path, snapshot)
    return {"ok": ok and snapshot["status"] == "restored", "status": snapshot["status"], "detail": detail,
            "moves": snapshot["moves"], "snapshot": str(path), "flags": snapshot["flags"],
            "proof": snapshot.get("proof"), "native_resume": snapshot.get("native_resume")}


def run_native_apply(native_path: Path, confirm: str) -> tuple[bool, str]:
    """Native apply with live progress and no timeout: killing a journaled move mid-step is unsafe."""
    command = ["bash", str(MIGRATE_HELPER), "apply", "--plan", str(native_path), "--confirm", confirm]
    try:
        result = subprocess.run(command, cwd=Path.home(), check=False)  # nosec B603
    except OSError as exc:
        return False, type(exc).__name__
    return result.returncode == 0, f"native apply exit {result.returncode}"


def apply_move(plan: dict[str, Any], sites: list[str] | None, confirm: str, repos_json: Path,
               state_dir: Path) -> dict[str, Any]:
    """Snapshot, pause, plan natively, apply, then restore or stay paused."""
    if plan["plan_sha256"] != confirm:
        raise FleetError("--confirm does not match the current fleet plan; preview again")
    moves = select_moves(plan, sites)
    slugs = [move["slug"] for move in moves]
    private_directory(state_dir)
    assert_no_unfinished(state_dir, slugs)
    stamp = int(time.time())
    path = state_dir / f"move-automation-{sha256_bytes(canonical_bytes(slugs))[:12]}-{stamp}.json"
    snapshot = {"status": "paused", "moves": moves,
                "flags": {slug: automation_flags(repos_json, slug) for slug in slugs}}
    save_snapshot(path, snapshot)
    pause(slugs)
    native_path = state_dir / f"move-layout-plan-{stamp}.json"
    try:
        native = write_native_plan(plan["workspace"], moves, native_path)
    except FleetError as exc:
        return finish(snapshot, path, repos_json, (False, str(exc)))
    snapshot["native_resume"] = (f"aidevops repos migrate-layout apply --plan {native_path} "
                                 f"--confirm {native['plan_sha256']}")
    save_snapshot(path, snapshot)
    return finish(snapshot, path, repos_json, run_native_apply(native_path, native["plan_sha256"]))


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
            "flags": {move["slug"]: automation_flags(repos_json, move["slug"]) for move in moves}}


def print_move(report: dict[str, Any]) -> None:
    """Human summary of a preview or an apply/restore result."""
    for move in report["moves"]:
        flags = report["flags"].get(move["slug"], {})
        print(f"  {move['slug']}: maintenance={flags.get('maintenance')} pulse={flags.get('pulse')}")
        print(f"    {move['source']} -> {move['destination']}")
    if "status" not in report:
        sites = " ".join(f"--site {site}" for site in report["sites"])
        print(f"Preview only. Apply with: fleet move {sites} --apply --confirm {report['plan_sha256']}")
        return
    print(f"Status: {report['status']} ({report['detail']})")
    print(f"Snapshot: {report['snapshot']}")
    if report["status"] == "paused-after-partial-move":
        print("Automation stays paused. Finish the native move, then restore:")
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
