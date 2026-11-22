"""Temporary inventory of observation-era worktrees; no database migration."""

import json
import os
import re
import time
from datetime import datetime
from pathlib import Path

from .enrollment import _git_directory
from .legacy_options import reconstructible_path, unrecorded
from .legacy_proc import require_ended, require_idle_processes
from .pull_requests import matches_open_pull_request
from .retirement import _git, _id


def unchanged(connection, plan, adapter):
    """Return True when the inventory row still matches the plan source."""
    current = next((item for item in inventory(connection)
                     if item["path"] == plan["source"]), None)
    confirmed = plan.get("operator_confirmed") is True
    if current is None and confirmed:
        current = unrecorded(plan["source"])
    if (current is None or current["modern"]
            or sorted(current["generations"]) != plan["generations"]
            or current["runs"] != plan["runs"]):
        raise ValueError("registered-writers-changed")
    require_ended(current, adapter, operator_confirmed=confirmed)


def requires_reconstructible(item, repositories, adapter, options):
    """Only missing writer evidence may select the independent recovery class."""
    try:
        inspect(item, repositories, adapter, time.time(), options)
    except ValueError as error:
        if str(error) == "no-recorded-processes":
            return True
        if str(error) == "too-recent" and (not item["runs"] or item["unbound"]):
            return True
        raise
    return False


def reconstructible(item, repositories, adapter, open_prs, managed_min_age=None):
    """Independent remote-recoverable class, never inferred from writer history.

    `managed_min_age` (seconds) selects the managed-takeover class and its idle floor;
    `None` keeps the observation-era class, whose age is checked by `inspect`.
    """
    managed = managed_min_age is not None
    path = reconstructible_path(item, managed)
    admin = _git_directory(path)
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common not in repositories or admin == Path(common):
        raise ValueError("repository-out-of-scope")
    if (admin / "locked").exists():
        raise ValueError("git-worktree-locked")
    if managed:
        require_age(item, path, admin, time.time(), managed_min_age)
    require_ended(item, adapter, operator_confirmed=True)
    # GH#36626 requires clean tracked and untracked state. Ignored files are
    # regenerable local artefacts, discarded like ordinary cleanup (CLEANUP.md).
    if _git("-C", str(path), "status", "--porcelain", "--untracked-files=all",
            "--ignore-submodules=none"):
        raise ValueError("nonempty-worktree-state")
    head = _git("-C", str(path), "rev-parse", "HEAD")
    if not _git("--git-dir", common, "for-each-ref", "--format=%(refname)",
                "--contains=" + head, "refs/remotes/"):
        raise ValueError("head-not-on-remote")
    branch = _git("-C", str(path), "rev-parse", "--symbolic-full-name", "HEAD")
    if branch != "HEAD" and not branch.startswith("refs/heads/"):
        raise ValueError("invalid-branch-ref")
    slug = repositories[common][0]
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", slug):
        raise ValueError("invalid-repository-slug")
    if matches_open_pull_request(open_prs(slug), head, branch, slug):
        raise ValueError("open-pull-request")
    # Native census for this platform: Linux /proc, macOS lsof (GH#37101). A
    # Linux-only call here retained every candidate on macOS Pulse hosts.
    require_idle_processes(path)
    return {"source": str(path), "directory": _id(path), "admin": str(admin),
            "admin_identity": _id(admin), "common": common, "head": head,
            "branch": branch, "repo": slug}


def inventory(connection):
    """Merge historical aliases before indexing their owners and admissions."""
    paths: dict[str, dict] = {}
    for row in connection.execute(
        "SELECT g.path,g.generation_id,r.run_id,r.identity FROM generations g "
        "LEFT JOIN bindings b USING(generation_id) LEFT JOIN runs r USING(run_id)"
    ):
        canonical_path = str(Path(row["path"]).resolve())
        item = paths.setdefault(canonical_path, {
            "path": canonical_path, "generations": set(), "runs": {}, "last_event": 0,
            "modern": False, "unbound": False,
        })
        item["generations"].add(row["generation_id"])
        if row["run_id"] is not None:
            item["runs"][row["run_id"]] = json.loads(row["identity"])
        else:
            item["unbound"] = True
    by_generation = {g: item for item in paths.values() for g in item["generations"]}
    by_run: dict[str, list[dict]] = {}
    for item in paths.values():
        for run in item["runs"]:
            by_run.setdefault(run, []).append(item)
    for row in connection.execute("SELECT payload,recorded_at FROM events"):
        payload = json.loads(row["payload"])
        generation = by_generation.get(payload.get("generation_id"))
        targets = list(by_run.get(payload.get("run_id"), []))
        if generation is not None:
            targets.append(generation)
            if payload.get("type") in ("open-admission", "admit", "created-worktree"):
                generation["modern"] = True
        stamp = datetime.fromisoformat(row["recorded_at"].replace("Z", "+00:00"))
        for item in targets:
            item["last_event"] = max(item["last_event"], stamp.timestamp())
    return sorted(paths.values(), key=lambda item: (item["last_event"], item["path"]))


def require_age(item, path, admin, now, min_age):
    """Require inactivity since the latest registry, directory, HEAD or index change."""
    latest = max(item["last_event"], path.stat().st_mtime,
                 (admin / "HEAD").stat().st_mtime)
    try:
        latest = max(latest, (admin / "index").stat().st_mtime)
    except FileNotFoundError:
        # Git permits an absent index, for example after add --no-checkout.
        pass
    if now - latest < min_age:
        raise ValueError("too-recent")


def inspect(item, repositories, adapter, now, options):
    """Age selects candidates; native identities are rechecked, never PID alone."""
    path = Path(item["path"])
    if item["modern"]:
        raise ValueError("managed-by-current-cleanup")
    if not os.path.lexists(path):
        raise ValueError("already-absent")
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError("noncanonical-path")
    if path.stat().st_uid != os.geteuid():
        raise ValueError("foreign-owner")
    cwd = Path.cwd().resolve()
    if cwd == path or cwd.is_relative_to(path):
        raise ValueError("current-working-tree")
    admin = _git_directory(path)
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute",
                  "--git-common-dir")
    if common not in repositories:
        raise ValueError("repository-out-of-scope")
    if (admin / "locked").exists():
        raise ValueError("git-worktree-locked")
    require_age(item, path, admin, now, options.min_age)
    require_ended(item, adapter,
                  operator_confirmed=item["path"] in options.confirmed_paths)
    return {"source": str(path), "directory": _id(path), "admin": str(admin),
            "admin_identity": _id(admin), "common": common,
            "generations": sorted(item["generations"]), "runs": item["runs"],
            "repo": repositories[common][0], "base": repositories[common][1]}
