"""Bounded registry-driven cleanup; repository configuration selects scope only."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess  # nosec B404 # classify helper exceptions, never execute error argv
import tempfile
import time
from uuid import UUID, uuid5

from .absence import _absent, path_reservations, reconcile_absence, reconcile_path
from .absence import reservation_blocker
from .archive_path import create_archive_root, validate_archive_path
from .admission import AdmissionRegistry
from .cleanup_failure import failure_details as _failure_details
from .cleanup_plan import enrolled_only_event_id
from .cleanup_quarantine import CleanupQuarantine
from .enrollment import MARKER, GenerationEnrollment, _git_directory
from .filesystem import validate_private_path as _private
from .interrupted_removal import journaled_removals, resume_failed, resume_first
from .legacy_proc import require_idle_processes
from .permissions import FilePolicy, read_owned_file
from .preservation import _helper, _retain_base, _snapshot, _verify
from .pull_requests import OpenPullRequestCache
from .retirement import ArchiveTarget, _event, _event_id, _git, _id, _lock, retire_worktree
from .storage import LifecycleRegistry, identifier

# Group write is accepted only for the owner's user-private group (umask 002).
REPOSITORY_CONFIG = FilePolicy("unsafe-repository-config", max_size=1048576, private=False)


def _repository_entries(config: Path) -> list:
    """Read a bounded operator-owned configuration without following links."""
    configuration = json.loads(read_owned_file(config, REPOSITORY_CONFIG).decode("utf-8"))
    if not isinstance(configuration, dict):
        raise ValueError("invalid-repository-config")
    entries = configuration.get("initialized_repos")
    if not isinstance(entries, list):
        raise ValueError("invalid-repository-config")
    return entries


def _repository_scope(entry: dict, *, explicit: bool = False) -> "tuple[str, str, str] | None":
    """Return the repository scope tuple for a registry entry, or None when excluded."""
    if not all((
        explicit or entry.get("maintenance", True) is True,
        entry.get("local_only", False) is False,
    )):
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


def _repositories(config: Path, *, explicit: bool = False) -> dict[str, tuple[str, str]]:
    """Read registered scope; only automatic cleanup requires maintenance."""
    result: dict[str, tuple[str, str]] = {}
    for entry in _repository_entries(config):
        if not isinstance(entry, dict):
            raise ValueError("invalid-repository-entry")
        scope = _repository_scope(entry, explicit=explicit)
        if scope is None:
            continue
        common, slug, base = scope
        if common in result:
            raise ValueError("ambiguous-repository-config")
        result[common] = (slug, base)
    return result


def _position(store: LifecycleRegistry) -> str:
    """Read the persisted cleanup position for the store."""
    path = store.directory / "cleanup-position"
    try:
        _private(path)
    except FileNotFoundError:
        return ""
    if path.stat().st_size > 64:
        raise ValueError("invalid-cleanup-position")
    return identifier(path.read_text(encoding="ascii").strip())


def _advance(store: LifecycleRegistry, row: dict) -> None:
    """Persist scheduling position before work; this file never grants authority.

    A resumed interrupted removal runs ahead of the rotation and keeps the cursor.
    """
    if row.get("resume"):
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="ascii", dir=store.directory,
            prefix=".cleanup-position-", delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(identifier(row["generation_id"]) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, store.directory / "cleanup-position")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _pull_request_hold(
    store: LifecycleRegistry, repositories: dict[str, tuple[str, str]],
    generation: str, path: Path, pull_requests: OpenPullRequestCache,
) -> str | None:
    """Return the automatic pass's fail-closed PR hold reason (GH#36851).

    A tree whose branch or HEAD has an open PR, or whose PR state cannot be
    read, is held before any mutation. An already-planned retirement always
    resumes, an absent source is left to reconciliation, and unmanaged
    repositories stay out of scope, so none of those are held here. Guards run
    in `_candidate` order, so a changed generation still fails, never holds.
    """
    if _event(store, _event_id(generation, "planned")) is not None:
        return None
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    if GenerationEnrollment(store).inspect(path) != generation:
        raise ValueError("cleanup-generation-changed")
    common = _git("-C", str(path), "rev-parse",
                  "--path-format=absolute", "--git-common-dir")
    if common not in repositories:
        return None
    return pull_requests.hold_reason(path, repositories[common][0])


def _candidate(
    store: LifecycleRegistry, repositories: dict[str, tuple[str, str]],
    root: Path, generation: str, path: Path,
) -> dict[str, object]:
    """Classify one worktree path as a cleanup candidate and return its result."""
    result: dict[str, object] = {
        "generation_id": generation, "status": "coverage-gap",
    }
    creation = _event(store, str(uuid5(UUID(generation), "created-worktree")))
    plan = _event(store, _event_id(generation, "planned"))
    if plan is not None:
        common = plan["common"]
    else:
        # A planned private relocation must resume instead of accepting absence.
        # lstat keeps dangling links distinct; access/metadata errors still fail.
        try:
            path.lstat()
        except FileNotFoundError:
            return reconcile_absence(store, path, generation)
        if GenerationEnrollment(store).inspect(path) != generation:
            raise ValueError("cleanup-generation-changed")
        common = _git("-C", str(path), "rev-parse",
                      "--path-format=absolute", "--git-common-dir")
    if common not in repositories:
        return dict(result, status="outside-maintenance-scope")
    slug, base = repositories[common]
    if plan is not None:
        slug, base, root = plan["repo"], plan["base"], Path(plan["output_root"])
    return retire_worktree(
        store, path, generation,
        ArchiveTarget(slug, base, root, recover=creation is None),
    )


def cleanup_worktree(
    store: LifecycleRegistry, config: Path, root: Path, path: Path,
) -> dict[str, object]:
    """Select the current generation once; never adopt or scan other candidates.

    A missing/relocated source requires an explicit generation-ID retirement retry.
    """
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    repositories = _repositories(config, explicit=True)
    generation = GenerationEnrollment(store).inspect_retirement(path)
    create_archive_root(root)
    validate_archive_path(root)
    return _candidate(store, repositories, root, generation, path)


def retire_enrolled_only(
    store: LifecycleRegistry, config: Path, root: Path, path: Path, confirm: bool,
) -> dict[str, object]:
    """Operator-confirmed, archive-first retirement of a never-owned generation.

    Eligible: enrolled, zero bound runs, no `created-worktree` receipt. Without
    `confirm` this only previews. Confirmation closes admission and records
    `operator_confirmed` evidence atomically, then reuses `retire_worktree`
    (archive, verify, private move, native removal); the branch is kept.
    """
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    repositories = _repositories(config, explicit=True)
    generation = GenerationEnrollment(store).inspect_retirement(path)
    with store.connection() as connection:
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
        owned = connection.execute(
            "SELECT 1 FROM bindings WHERE generation_id=?", (generation,),
        ).fetchone() or _event(store, str(uuid5(UUID(generation), "created-worktree")))
    result: dict[str, object] = {
        "generation_id": generation, "cleanup_authorized": False,
        "admission": admission["state"] if admission else "absent",
    }
    if admission is None or owned:
        return dict(result, status="not-enrolled-only")
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute",
                  "--git-common-dir")
    if common not in repositories:
        return dict(result, status="outside-maintenance-scope")
    if not confirm:
        return dict(result, status="enrolled-only-preview", confirm_required=True)
    if root.is_relative_to(path) or root.is_relative_to(_git_directory(path)):
        raise ValueError("archive-output-must-be-outside-worktree")
    create_archive_root(root)
    validate_archive_path(root)
    AdmissionRegistry(store).authorize_enrolled_only(
        enrolled_only_event_id(generation), generation,
    )
    return _candidate(store, repositories, root, generation, path)


def _stale_reservation(store: LifecycleRegistry, path: Path) -> tuple[str | None, str]:
    """Return (generation, "") for a reused path, else (None, refusal reason).

    The tree's own Git admin must have no marker, and exactly one closed
    reservation by another generation may hold the pathname.
    """
    if os.path.lexists(_git_directory(path) / MARKER):
        return None, "generation-marker-present"
    rows = path_reservations(store, path)
    if len(rows) != 1:
        return None, "single-reservation-required" if rows else "no-reservation"
    if rows[0]["state"] != "closed":
        return None, "closed-reservation-required"
    return identifier(rows[0]["generation_id"]), ""


def _archive_and_remove(
    store: LifecycleRegistry, path: Path, generation: str,
    target: ArchiveTarget, common: str,
) -> dict[str, object]:
    """Archive and verify the unenrolled tree, journal it, then remove it natively.

    The idle census runs before and after capture; any content or identity
    change after capture refuses removal and keeps the tree.
    """
    identity = _id(path)
    require_idle_processes(path)
    snapshot = _snapshot(path)
    archive = Path(_helper(
        "archive", str(path), "--repo", target.repository, "--unattributed",
        "--reason", "unattributed-worktree", "--base-branch", target.base_branch,
        "--output-root", str(target.root),
    ))
    manifest = _verify(archive, path, target.root, snapshot)
    operation = str(uuid5(UUID(generation), "reused-path-archive:" + str(archive)))
    base_reference = _retain_base(path, operation, manifest["base_sha"])
    receipt: dict[str, object] = {
        "type": "reused-path-archived", "generation_id": generation, "path": str(path),
        "archive": str(archive), "snapshot": snapshot, "base_sha": manifest["base_sha"],
        "base_ref": base_reference, "operator_confirmed": True,
        "common_repository_required": True,
    }
    with store.connection(write=True) as connection:
        store._event(connection, operation, receipt)
    require_idle_processes(path)
    if (_id(path) != identity or _snapshot(path) != snapshot
            or os.path.lexists(_git_directory(path) / MARKER)):
        raise ValueError("reused-source-changed")
    _git("--git-dir", common, "worktree", "remove", "--force", str(path))
    return dict(receipt, operation_id=operation)


def recover_reused_path(
    store: LifecycleRegistry, config: Path, root: Path, path: Path, confirm: bool,
) -> dict[str, object]:
    """Operator-confirmed recovery of a fixed path re-created over a stale reservation.

    GH#37706: a linked tree without a generation marker occupies a path still
    reserved by one closed generation with no retirement plan, so neither
    enrollment nor absence reconciliation can proceed. Without `confirm` this
    only previews. Confirmation archives and verifies the unenrolled tree
    (ignored files are not captured), removes it natively, then releases the
    stale reservation through the fenced `reconcile_absence`. Branch is kept.
    An absent path (for example after an interrupted recovery) only reconciles.
    """
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    if not path.is_absolute():
        raise ValueError("absolute-path-required")
    if _absent(path):
        return reconcile_path(store, path)
    if path.is_symlink() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("canonical-path-required")
    repositories = _repositories(config, explicit=True)
    result: dict[str, object] = {"path": str(path), "cleanup_authorized": False}
    generation, reason = _stale_reservation(store, path)
    if generation is None:
        return dict(result, status="not-reused-path", reason=reason)
    result["generation_id"] = generation
    blocker = reservation_blocker(store, path, generation)
    if blocker is not None:
        return dict(result, status=blocker)
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute",
                  "--git-common-dir")
    if common not in repositories:
        return dict(result, status="outside-maintenance-scope")
    slug, base = repositories[common]
    if not confirm:
        return dict(result, status="reused-path-preview", confirm_required=True,
                    repo=slug, base_branch=base, ignored_files="not-archived")
    if root.is_relative_to(path) or root.is_relative_to(_git_directory(path)):
        raise ValueError("archive-output-must-be-outside-worktree")
    create_archive_root(root)
    validate_archive_path(root)
    with _lock(store, generation):
        # Recheck under the generation lock shared with retirement and reconciliation.
        if (_stale_reservation(store, path)[0] != generation
                or reservation_blocker(store, path, generation) is not None):
            raise ValueError("reused-path-changed")
        archived = _archive_and_remove(
            store, path, generation, ArchiveTarget(slug, base, root), common,
        )
    reconciliation = reconcile_absence(store, path, generation)
    status = ("reused-path-recovered"
              if reconciliation.get("status") == "source-absent-reconciled"
              else "reused-tree-archived-reservation-retained")
    return dict(result, status=status, archive=archived["archive"],
                operation_id=archived["operation_id"], base_ref=archived["base_ref"],
                reconciliation=reconciliation)


def cleanup_pass(
    store: LifecycleRegistry, config: Path, root: Path,
    limit: int = 25, budget_seconds: float = 120,
) -> dict:
    """Budget between operations; the caller owns the hard watchdog.

    No filesystem census, age policy, branch removal or broad Git pruning.
    One fail-closed PR hold applies: an open PR on the tree's branch or HEAD, or
    unreadable PR state, keeps the tree (GH#36851). A legacy/enrolled-only
    generation remains ineligible for retirement.
    """
    if not 1 <= limit <= 1000 or not 0 < budget_seconds <= 900:
        raise ValueError("invalid-cleanup-budget")
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError("canonical-archive-root-required")
    namespace = UUID(store.installation_id())
    report: dict = {"status": "cleanup-pass", "examined": 0, "retired": 0,
                    "held": 0, "failed": 0, "archive_failed": 0, "reconciled": 0,
                    "results": [],
                    "cleanup_authorized": False}
    with _lock(store, str(uuid5(namespace, "cleanup-pass"))):
        repositories = _repositories(config)
        with store.connection() as connection:
            rows = [dict(row) for row in connection.execute(
                "SELECT generation_id,path,state FROM generation_admissions "
                "ORDER BY generation_id",
            )]
            journaled = journaled_removals(connection, rows, _event_id)
        after = _position(store)
        rows.sort(key=lambda row: (row["generation_id"] <= after, row["generation_id"]))
        deadline = time.monotonic() + budget_seconds
        create_archive_root(root)
        validate_archive_path(root)
        quarantine = CleanupQuarantine(store.directory)
        pull_requests = OpenPullRequestCache()
        selected, report["quarantined"] = quarantine.partition(rows)
        # Reclaim one interrupted native removal before the rotation (GH#37326).
        selected = resume_first(selected, journaled.__contains__)
        for row in selected[:limit]:
            if time.monotonic() >= deadline:
                break
            generation, path = identifier(row["generation_id"]), Path(row["path"])
            _advance(store, row)
            report["examined"] += 1
            try:
                reason = _pull_request_hold(store, repositories, generation, path,
                                            pull_requests)
                result = (_candidate(store, repositories, root, generation, path)
                          if reason is None else
                          {"generation_id": generation, "status": "held", "reason": reason})
                counter = {"retired": "retired", "source-absent-reconciled": "reconciled"}
                report[counter.get(str(result["status"]), "held")] += 1
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                report["failed"] += 1
                result = {"generation_id": generation, "status": "unavailable",
                          **_failure_details(error)}
            result["path"] = str(path)
            report["archive_failed"] += bool(result.get("archive_failure", False))
            quarantine.record(row["generation_id"], result, resume_failed(row, result))
            report["results"].append(result)
        quarantine.save(report)
    return report
