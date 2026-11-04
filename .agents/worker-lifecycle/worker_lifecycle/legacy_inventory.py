"""Temporary inventory of observation-era worktrees; no database migration."""

import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path

from .enrollment import _git_directory
from .filesystem import validate_private_path as _private
from .process import ProcessIdentity
from .retirement import _git, _id


def require_idle_proc(path, proc=Path("/proc")):
    """Linux same-UID cwd/fd census; disappearing tasks are not unreadable tasks."""
    if not (proc / "self").exists():
        raise ValueError("proc-observation-unavailable")
    try:
        for task in proc.iterdir():
            if not task.name.isdecimal():
                continue
            try:
                if task.stat().st_uid != os.geteuid():
                    continue
                references = [task / "cwd"] + list((task / "fd").iterdir())
                for reference in references:
                    try:
                        target = Path(os.readlink(reference).removesuffix(" (deleted)"))
                    except FileNotFoundError:
                        continue
                    if target == path or path in target.parents:
                        raise ValueError("live-process-reference")
            except FileNotFoundError:
                continue
    except OSError as error:
        raise ValueError("proc-observation-unavailable") from error


def reconstructible(item, repositories, adapter, open_prs):
    """Independent remote-recoverable class, never inferred from writer history."""
    path = Path(item["path"])
    base = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                               Path.home() / "Git" / "_worktrees")).expanduser()
    if (not base.is_absolute() or base.resolve() != base
            or path.resolve(strict=True) != path or not path.is_relative_to(base)
            or path == base):
        raise ValueError("outside-managed-worktree-base")
    patterns = ["preserved", "readonly", "recovery", "review"]
    patterns.extend(filter(None, os.environ.get(
        "AIDEVOPS_WORKTREE_PRESERVE_PATTERNS", "").lower().split(",")))
    if any(pattern in path.name.lower() for pattern in patterns):
        raise ValueError("preservation-name")
    if item["modern"] or path.stat().st_uid != os.geteuid():
        raise ValueError("managed-or-foreign-worktree")
    admin = _git_directory(path)
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common not in repositories or admin == Path(common):
        raise ValueError("repository-out-of-scope")
    if (admin / "locked").exists():
        raise ValueError("git-worktree-locked")
    require_ended(item, adapter, operator_confirmed=True)
    if _git("-C", str(path), "status", "--porcelain", "--untracked-files=all",
            "--ignored", "--ignore-submodules=none"):
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
    for pr in open_prs(slug):
        if (pr["head"]["sha"] == head
                or (branch != "HEAD" and pr["head"]["ref"] == branch[11:])):
            raise ValueError("open-pull-request")
    require_idle_proc(path)
    return {"source": str(path), "directory": _id(path), "admin": str(admin),
            "admin_identity": _id(admin), "common": common, "head": head,
            "branch": branch, "repo": slug}


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


def require_ended(item, adapter, *, operator_confirmed=False):
    for value in item["runs"].values():
        observed = adapter.observe(ProcessIdentity.from_dict(value))
        if observed.status != "ended":
            raise ValueError("process-" + observed.status)
    if not operator_confirmed and (not item["runs"] or item["unbound"]):
        raise ValueError("no-recorded-processes")


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
    latest = max(item["last_event"], path.stat().st_mtime,
                 (admin / "HEAD").stat().st_mtime)
    try:
        latest = max(latest, (admin / "index").stat().st_mtime)
    except FileNotFoundError:
        # Git permits an absent index, for example after add --no-checkout.
        # Archive verification still validates the actual index/working state.
        pass
    if now - latest < options.min_age:
        raise ValueError("too-recent")
    require_ended(item, adapter,
                  operator_confirmed=item["path"] in options.confirmed_paths)
    return {"source": str(path), "directory": _id(path), "admin": str(admin),
            "admin_identity": _id(admin), "common": common,
            "generations": sorted(item["generations"]), "runs": item["runs"],
            "repo": repositories[common][0], "base": repositories[common][1]}
