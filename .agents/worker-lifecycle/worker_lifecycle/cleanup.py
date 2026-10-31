"""Bounded registry-driven cleanup; repository configuration selects scope only."""

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time
from uuid import UUID, uuid5

from .enrollment import GenerationEnrollment
from .retirement import ArchiveTarget, _event, _event_id, _git, _lock, retire_worktree
from .storage import LifecycleRegistry, _private, identifier


def _repository_entries(config: Path) -> list:
    """Read a bounded operator-owned configuration without following links."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(config, flags), "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if info.st_size > 1048576:
            raise ValueError("unsafe-repository-config")
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o022 or info.st_nlink != 1):
            raise ValueError("unsafe-repository-config")
        configuration = json.load(stream)
    if not isinstance(configuration, dict):
        raise ValueError("invalid-repository-config")
    entries = configuration.get("initialized_repos")
    if not isinstance(entries, list):
        raise ValueError("invalid-repository-config")
    return entries


def _repository_scope(entry: dict) -> "tuple[str, str, str] | None":
    if (entry.get("maintenance", True) is not True
            or entry.get("local_only", False) is not False):
        return None
    slug, location = entry.get("slug"), entry.get("path")
    if (not isinstance(slug, str) or not isinstance(location, str)
            or not re.fullmatch(r"[\w.-]+/[\w.-]+", slug, flags=re.ASCII)):
        return None
    try:
        repo = Path(location).expanduser().resolve(strict=True)
        if not (repo / ".git").is_dir() or (repo / ".git").is_symlink():
            return None
        common = _git("-C", str(repo), "rev-parse", "--path-format=absolute",
                      "--git-common-dir")
        # Use an actual branch, not a guessed default or a SHA as a branch name.
        base = _git("-C", str(repo), "symbolic-ref", "--short", "HEAD")
    except (FileNotFoundError, subprocess.CalledProcessError):
        # Missing or detached registrations cannot establish repository scope.
        return None
    return common, slug, base


def _repositories(config: Path) -> dict[str, tuple[str, str]]:
    """Read operator scope without network calls or consulting legacy owners."""
    result: dict[str, tuple[str, str]] = {}
    for entry in _repository_entries(config):
        if not isinstance(entry, dict):
            raise ValueError("invalid-repository-entry")
        scope = _repository_scope(entry)
        if scope is None:
            continue
        common, slug, base = scope
        if common in result:
            raise ValueError("ambiguous-repository-config")
        result[common] = (slug, base)
    return result


def _position(store: LifecycleRegistry) -> str:
    path = store.directory / "cleanup-position"
    try:
        _private(path)
    except FileNotFoundError:
        return ""
    if path.stat().st_size > 64:
        raise ValueError("invalid-cleanup-position")
    return identifier(path.read_text(encoding="ascii").strip())


def _advance(store: LifecycleRegistry, generation: str) -> None:
    """Persist scheduling position before work; this file never grants authority."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="ascii", dir=store.directory,
            prefix=".cleanup-position-", delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(generation + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, store.directory / "cleanup-position")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _candidate(
    store: LifecycleRegistry, repositories: dict[str, tuple[str, str]],
    root: Path, generation: str, path: Path,
) -> dict[str, object]:
    result: dict[str, object] = {
        "generation_id": generation, "status": "coverage-gap",
    }
    creation = _event(store, str(uuid5(UUID(generation), "created-worktree")))
    if creation is None:
        return result
    plan = _event(store, _event_id(generation, "planned"))
    if plan is not None:
        common = plan["common"]
    else:
        if GenerationEnrollment(store).inspect(path) != generation:
            raise ValueError("cleanup-generation-changed")
        common = _git("-C", str(path), "rev-parse",
                      "--path-format=absolute", "--git-common-dir")
    if common not in repositories:
        return dict(result, status="outside-maintenance-scope")
    slug, base = repositories[common]
    if plan is not None:
        slug, base, root = plan["repo"], plan["base"], Path(plan["output_root"])
    return retire_worktree(store, path, generation, ArchiveTarget(slug, base, root))


def cleanup_worktree(
    store: LifecycleRegistry, config: Path, root: Path, path: Path,
) -> dict[str, object]:
    """Select the current generation once; never adopt or scan other candidates.

    A missing/relocated source requires an explicit generation-ID retirement retry.
    """
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    repositories = _repositories(config)
    generation = GenerationEnrollment(store).inspect(path)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(root, directory=True)
    return _candidate(store, repositories, root, generation, path)


def cleanup_pass(
    store: LifecycleRegistry, config: Path, root: Path,
    limit: int = 25, budget_seconds: float = 120,
) -> dict:
    """Budget between operations; the caller owns the hard watchdog.

    No filesystem census, PR/age policy, branch removal or broad Git pruning.
    A legacy/enrolled-only generation remains ineligible for retirement.
    """
    if not 1 <= limit <= 1000 or not 0 < budget_seconds <= 900:
        raise ValueError("invalid-cleanup-budget")
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    namespace = UUID(store.installation_id())
    report: dict = {"status": "cleanup-pass", "examined": 0, "retired": 0,
                    "held": 0, "failed": 0, "results": [],
                    "cleanup_authorized": False}
    with _lock(store, str(uuid5(namespace, "cleanup-pass"))):
        repositories = _repositories(config)
        with store.connection() as connection:
            rows = [dict(row) for row in connection.execute(
                "SELECT generation_id,path FROM generation_admissions "
                "ORDER BY generation_id",
            )]
        after = _position(store)
        rows.sort(key=lambda row: (row["generation_id"] <= after, row["generation_id"]))
        deadline = time.monotonic() + budget_seconds
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        _private(root, directory=True)
        for row in rows[:limit]:
            if time.monotonic() >= deadline:
                break
            generation, path = identifier(row["generation_id"]), Path(row["path"])
            _advance(store, generation)
            report["examined"] += 1
            try:
                result = _candidate(store, repositories, root, generation, path)
                report["retired" if result["status"] == "retired" else "held"] += 1
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                report["failed"] += 1
                result = {"generation_id": generation, "status": "unavailable",
                          "reason": type(error).__name__}
            report["results"].append(result)
    return report
