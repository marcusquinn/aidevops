"""Temporary inventory of observation-era worktrees; no database migration."""

import json
import os
import tempfile
from datetime import datetime
from pathlib import Path

from .enrollment import _git_directory
from .process import ProcessIdentity
from .retirement import _git, _id
from .storage import _private


def queue(store, items):
    """A private cursor gives bounded passes fair progress; it grants no authority."""
    cursor = store.directory / "legacy-cleanup-position"
    position = ""
    if os.path.lexists(cursor):
        _private(cursor)
        if cursor.stat().st_size > 8192:
            raise ValueError("invalid-legacy-cleanup-position")
        position = json.loads(cursor.read_text(encoding="utf-8"))
        if not isinstance(position, str):
            raise ValueError("invalid-legacy-cleanup-position")
    ordered = sorted(items, key=lambda item: item["path"])
    return ([item for item in ordered if item["path"] > position]
            + [item for item in ordered if item["path"] <= position])


def advance(store, path):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                         dir=store.directory, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(path, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, store.directory / "legacy-cleanup-position")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def inventory(connection):
    """Group historical generations by path, including missing directories."""
    paths: dict[str, dict] = {}
    for row in connection.execute(
        "SELECT g.path,g.generation_id,r.run_id,r.identity FROM generations g "
        "LEFT JOIN bindings b USING(generation_id) LEFT JOIN runs r USING(run_id)"
    ):
        item = paths.setdefault(row["path"], {
            "path": row["path"], "generations": set(), "runs": {}, "last_event": 0,
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


def require_ended(item, adapter):
    if not item["runs"] or item["unbound"]:
        raise ValueError("no-recorded-processes")
    for value in item["runs"].values():
        observed = adapter.observe(ProcessIdentity.from_dict(value))
        if observed.status != "ended":
            raise ValueError("process-" + observed.status)


def inspect(item, repositories, adapter, now, min_age):
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
    latest = max(item["last_event"], path.stat().st_mtime,
                 (admin / "HEAD").stat().st_mtime, (admin / "index").stat().st_mtime)
    if now - latest < min_age:
        raise ValueError("too-recent")
    require_ended(item, adapter)
    return {"source": str(path), "directory": _id(path), "admin": str(admin),
            "admin_identity": _id(admin), "common": common,
            "generations": sorted(item["generations"]), "runs": item["runs"],
            "repo": repositories[common][0], "base": repositories[common][1]}
