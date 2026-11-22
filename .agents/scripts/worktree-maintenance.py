#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Explicit legacy maintenance; plans never authorize ordinary background cleanup."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

import worktree_maintenance_boundary as boundary
import worktree_maintenance_worker as worker
from worktree_maintenance_commands import command, executable, git, repository

SCHEMA = "aidevops.worktree-maintenance/v2"
SCRIPTS = Path(__file__).resolve().parent
require = boundary.require


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def machine():
    identity = Path("/etc/machine-id").read_bytes().strip()
    require(re.fullmatch(rb"[0-9a-f]{32}", identity) is not None
            and identity != b"0" * 32, "maintenance:invalid-machine-id")
    return hashlib.sha256(identity).hexdigest()


def database():
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    path = Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")
    require(path.is_file() and not path.is_symlink(), "maintenance:registry-unavailable")
    return path.resolve().as_uri() + "?mode=ro"


owner = worker.owner
legacy_observation = worker.legacy_observation


def legacy(path):
    return worker.legacy(database(), path)


def preservation_checks(path, discard_ignored=False):
    for marker in (".aidevops-preserve-forensics", ".preserve-forensics", ".aidevops-security-incident"):
        require(not os.path.lexists(path / marker), "maintenance:preserve-forensics")
    # The current producer captures Git/untracked data, not ignored content.
    # Only an explicit worker-plan decision can discard ignored content.
    require(discard_ignored or not git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"),
            "maintenance:ignored-content-requires-preservation")


def candidate(path, repo):
    require(path.is_absolute() and str(path) == os.path.realpath(path) and not path.is_symlink(),
            "maintenance:noncanonical-path")
    boundary.observe()
    # Classify enrollment and registered ownership first. Managed generations
    # belong to ordinary lifecycle cleanup, not this legacy-only authorization.
    # Unrelated denied CWDs must not hide that distinction or a live owner.
    record = legacy(path)
    boundary.require_unused(path)
    preservation_checks(path)
    require(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir") ==
            git(repo["path"], "rev-parse", "--path-format=absolute", "--git-common-dir"),
            "maintenance:repository-mismatch")
    require(not git(path, "status", "--porcelain", "--untracked-files=all"), "maintenance:dirty-worktree")
    require(git(path, "rev-list", "--count", "HEAD", "--not", repo["tip"]) == "0",
            "maintenance:head-not-in-default-history")
    branch = git(path, "symbolic-ref", "--short", "HEAD")
    prs = json.loads(command(["gh", "pr", "list", "--repo", repo["slug"], "--head", branch,
                              "--state", "open", "--limit", "1", "--json", "number"]))
    require(prs == [], "maintenance:open-pr")
    try:
        command(["bash", str(SCRIPTS / "worktree-maintenance-policy.sh"), str(path), branch, repo["slug"]])
    except ValueError as error:
        raise ValueError("maintenance:retention-policy-not-clear") from error
    return {"path": str(path), "head": git(path, "rev-parse", "HEAD"), "branch": branch,
            "record_digest": digest(record), "identity": record["identity"]}


def worker_candidate(path, repo, selection):
    require(path.is_absolute() and str(path) == os.path.realpath(path) and not path.is_symlink(),
            "maintenance:noncanonical-path")
    boundary.observe()
    witness = worker.evidence(path, selection)
    snapshot = worker.require_unused(path)
    binding = worker.legacy_binding(database(), path, snapshot)
    identity = binding["identity"]
    preservation_checks(path, selection["discard_ignored"])
    require(identity["common"] == git(repo["path"], "rev-parse", "--path-format=absolute", "--git-common-dir"),
            "maintenance:repository-mismatch")
    require(not git(path, "status", "--porcelain", "--untracked-files=all"), "maintenance:dirty-worktree")
    ahead = int(git(path, "rev-list", "--count", "HEAD", "--not", repo["tip"]))
    require(ahead == 0 or selection["archive_local_commits"], "maintenance:local-commits-require-archive-policy")
    branch = git(path, "symbolic-ref", "--short", "HEAD")
    policy_args = ["bash", str(SCRIPTS / "worktree-maintenance-policy.sh"), str(path), branch, repo["slug"]]
    if selection["archive_blocked"]:
        policy_args.append("--archive-blocked")
    command(policy_args)
    return {"path": str(path), "head": git(path, "rev-parse", "HEAD"), "branch": branch,
            "identity": identity, "lifecycle_record_sha256": binding["lifecycle_record_sha256"],
            "local_commits": ahead, "worker_evidence": witness}


def worker_plan(repo_path, path, selection):
    repo = repository(repo_path.resolve(strict=True))
    entry = worker_candidate(path, repo, selection)
    return {"schema": SCHEMA, "machine": machine(), "uid": os.getuid(), "created_at": time.time(),
            "repository": repo, "worker_policy": selection,
            "entries": [dict(entry, decision="candidate")]}


def create_plan(args):
    options = (args.worker_path, args.worker_launch_log, args.worker_runtime_log)
    policies = (args.discard_ignored, args.archive_local_commits, args.archive_blocked)
    if any(options + policies):
        require(all(options), "maintenance:worker-path-and-both-native-logs-required")
        selection = {"policy": worker.POLICY, "launch_log": str(args.worker_launch_log),
                      "runtime_log": str(args.worker_runtime_log), "discard_ignored": args.discard_ignored,
                      "archive_local_commits": args.archive_local_commits, "archive_blocked": args.archive_blocked}
        return worker_plan(args.repo, args.worker_path, selection)
    return plan(args.repo, args.limit, args.offset)


def plan(repo_path, limit=50, offset=0):
    require(1 <= limit <= 200 and offset >= 0, "maintenance:invalid-plan-range")
    repo = repository(repo_path.resolve(strict=True))
    worktrees = []
    for block in git(repo_path, "worktree", "list", "--porcelain").split("\n\n"):
        lines = block.splitlines()
        if not lines or not lines[0].startswith("worktree "):
            continue
        path = Path(lines[0][9:])
        if str(path) == repo["path"]:
            continue
        worktrees.append((path, lines))
    entries = []
    selected = worktrees[offset:offset + limit]
    for path, lines in selected:
        try:
            require(not any(line == "locked" or line.startswith("locked ") for line in lines),
                    "maintenance:git-locked")
            entry = candidate(path, repo)
            entries.append(dict(entry, decision="candidate"))
        except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
            entries.append({"path": str(path), "decision": "retain", "reason": str(error)})
        if len(entries) % 10 == 0 or len(entries) == len(selected):
            print(f"Maintenance plan: evaluated {len(entries)}/{len(selected)} worktrees",
                  file=sys.stderr, flush=True)
    next_offset = offset + len(selected)
    return {"schema": SCHEMA, "machine": machine(), "uid": os.getuid(), "created_at": time.time(),
            "repository": repo, "entries": entries,
            "scan": {"total_worktrees": len(worktrees), "offset": offset, "examined": len(selected),
                     "next_offset": next_offset if next_offset < len(worktrees) else None}}


def load_plan(path, confirmation):
    require(path.is_absolute() and path.is_file() and not path.is_symlink(), "maintenance:invalid-plan-path")
    require(path.stat().st_size <= 4 * 1024 * 1024, "maintenance:plan-too-large")
    value = json.loads(path.read_text())
    require(value.get("schema") == SCHEMA and digest(value) == confirmation, "maintenance:plan-token-mismatch")
    require(value.get("machine") == machine(), "maintenance:wrong-machine")
    require(value.get("uid") == os.getuid(), "maintenance:wrong-user")
    require(0 <= time.time() - value["created_at"] <= 7 * 86400, "maintenance:plan-expired")
    paths = [entry["path"] for entry in value["entries"]]
    require(len(paths) == len(set(paths)), "maintenance:duplicate-path")
    return value


def proof(path, plan_path, confirmation):
    context = boundary.observe()
    value = load_plan(plan_path, confirmation)
    # Native removal calls this directly, without passing through apply(). The
    # checksum confirms plan selection; it does not authenticate its Git claims.
    require(repository(Path(value["repository"]["path"])) == value["repository"],
            "maintenance:repository-changed")
    expected = next((entry for entry in value["entries"] if entry["path"] == str(path)
                     and entry["decision"] == "candidate"), None)
    require(expected is not None, "maintenance:path-not-approved")
    selection = value.get("worker_policy")
    if selection is not None:
        worker.validate_selection(selection)
        observed = worker_candidate(path, value["repository"], selection)
    else:
        observed = candidate(path, value["repository"])
    require(observed == {key: item for key, item in expected.items() if key != "decision"},
            "maintenance:candidate-changed")
    require(boundary.observe() == context, "maintenance:boundary-changed")
    return context


def apply(plan_path, confirmation):
    boundary.observe()
    value = load_plan(plan_path, confirmation)
    require(repository(Path(value["repository"]["path"])) == value["repository"],
            "maintenance:repository-changed")
    env = dict(os.environ, AIDEVOPS_WORKTREE_MAINTENANCE_PLAN=str(plan_path),
               AIDEVOPS_WORKTREE_MAINTENANCE_CONFIRM=confirmation,
               AIDEVOPS_WORKTREE_MAINTENANCE_KEEP_BRANCH="1" if value.get("worker_policy") is not None else "0",
               AIDEVOPS_WORKTREE_MANAGER="legacy-guards", PYTHONDONTWRITEBYTECODE="1")
    for entry in value["entries"]:
        if entry["decision"] != "candidate":
            continue
        path = Path(entry["path"])
        context = proof(path, plan_path, confirmation)
        # No --force: dirty changes and locks acquired after planning still veto.
        # Existing archive-first removal independently verifies restoration of its
        # Git capture. Ignored content is refused unless the selected worker
        # policy explicitly classifies it as disposable; forensic vetoes remain.
        # This module never removes files or changes receipts.
        # Fixed repository helper and operation; the approved path is a positional argument.
        result = subprocess.run(  # nosec B603
                                [executable("bash"), str(SCRIPTS / "worktree-helper.sh"), "remove", str(path)],
                                cwd=value["repository"]["path"], env=env, stdin=subprocess.DEVNULL,
                                timeout=600, check=False)
        print(json.dumps({"plan": confirmation, "path": str(path), "boundary": context,
                          "exit_code": result.returncode, "source_present": path.exists()}), flush=True)
        require(result.returncode == 0 and not path.exists(), "maintenance:removal-incomplete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    create = commands.add_parser("plan")
    create.add_argument("--repo", type=Path, required=True)
    create.add_argument("--limit", type=int, default=50)
    create.add_argument("--offset", type=int, default=0)
    create.add_argument("--worker-path", type=Path)
    create.add_argument("--worker-launch-log", type=Path)
    create.add_argument("--worker-runtime-log", type=Path)
    create.add_argument("--discard-ignored", action="store_true")
    create.add_argument("--archive-local-commits", action="store_true")
    create.add_argument("--archive-blocked", action="store_true")
    for action in ("check", "apply", "proof"):
        check = commands.add_parser(action)
        check.add_argument("--plan", type=Path, required=True)
        check.add_argument("--confirm", required=True)
        if action == "proof":
            check.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "plan":
            value = create_plan(args)
            print(json.dumps(value, indent=2))
            print("Confirmation token: " + digest(value), file=sys.stderr)
        elif args.operation == "apply":
            apply(args.plan, args.confirm)
        elif args.operation == "proof":
            proof(args.path, args.plan, args.confirm)
        else:
            context = boundary.observe()
            value = load_plan(args.plan, args.confirm)
            require(repository(Path(value["repository"]["path"])) == value["repository"],
                    "maintenance:repository-changed")
            for entry in value["entries"]:
                if entry["decision"] == "candidate":
                    proof(Path(entry["path"]), args.plan, args.confirm)
            require(boundary.observe() == context, "maintenance:boundary-changed")
            print(json.dumps({"boundary": context, "plan": digest(value), "deletion_authorized": False}))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
