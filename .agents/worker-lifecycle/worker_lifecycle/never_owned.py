# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Archive-first retirement of never-owned enrolled generations.

A never-owned tree is enrolled, has zero bound runs and no `created-worktree`
receipt, so it cannot prove its owners ended. `reclaim_unowned` authorizes it on
checked evidence (``reclaim.unowned``, GH#38405); `retire_enrolled_only` is the
legacy operator-confirmed path (GH#36516), removed with the legacy cleanup path.
Both reuse the cleanup executor (archive, verify, private move, native removal)
and keep the branch.
"""

from __future__ import annotations

from pathlib import Path
from uuid import UUID, uuid5

from .admission import AdmissionRegistry
from .archive_path import create_archive_root, validate_archive_path
from .cleanup import _candidate, _repositories
from .cleanup_plan import enrolled_only_event_id
from .enrollment import GenerationEnrollment, _git_directory
from .legacy_proc import require_idle_processes
from .protected_proc import ProcessCensusUnavailable
from .reclaim.evidence import references
from .reclaim.unowned import authorize as authorize_unowned, unowned_authorized
from .retirement import _event, _git
from .storage import LifecycleRegistry

__all__ = ["reclaim_unowned", "retire_enrolled_only"]


def _never_owned(
    store: LifecycleRegistry, config: Path, root: Path, path: Path,
) -> tuple[str, dict[str, tuple[str, str]], dict[str, object]]:
    """Shared never-owned eligibility; a ``status`` in the result means ineligible.

    Eligible: enrolled, zero bound runs, no `created-worktree` receipt, and the
    tree's repository in the explicit maintenance scope.
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
        return generation, repositories, dict(result, status="not-enrolled-only")
    common = _git("-C", str(path), "rev-parse", "--path-format=absolute",
                  "--git-common-dir")
    if common not in repositories:
        return generation, repositories, dict(result, status="outside-maintenance-scope")
    return generation, repositories, result


def _prepare_archive_root(root: Path, path: Path) -> None:
    if root.is_relative_to(path) or root.is_relative_to(_git_directory(path)):
        raise ValueError("archive-output-must-be-outside-worktree")
    create_archive_root(root)
    validate_archive_path(root)


def retire_enrolled_only(
    store: LifecycleRegistry, config: Path, root: Path, path: Path, confirm: bool,
) -> dict[str, object]:
    """Legacy operator-confirmed retirement; `reclaim_unowned` replaces it.

    Without `confirm` this only previews. Confirmation closes admission and
    records `operator_confirmed` evidence atomically, then retires.
    """
    generation, repositories, result = _never_owned(store, config, root, path)
    if "status" in result:
        return result
    if not confirm:
        return dict(result, status="enrolled-only-preview", confirm_required=True)
    _prepare_archive_root(root, path)
    AdmissionRegistry(store).authorize_enrolled_only(
        enrolled_only_event_id(generation), generation,
    )
    return _candidate(store, repositories, root, generation, path)


def reclaim_unowned(
    store: LifecycleRegistry, config: Path, root: Path, path: Path,
) -> dict[str, object]:
    """Evidence-backed retirement: no operator confirmation (GH#38405).

    Reclaim checks no process uses the tree and it has nothing to lose, and
    journals the facts with admission closure, then retires. Any refused fact
    keeps the tree, reported as ``reclaim-refused`` with the reason. A never-owned
    tree has no recorded runs, so the process census runs before authorization,
    not only inside retirement; retirement repeats it at the removal location.
    """
    generation, repositories, result = _never_owned(store, config, root, path)
    if "status" in result:
        return result
    _prepare_archive_root(root, path)
    try:
        require_idle_processes(path)
    except ProcessCensusUnavailable:
        raise  # Structured with its observation by cli_errors; admission unchanged.
    except ValueError as error:
        return _refused(store, generation, result, str(error))
    found = [f"{kind}{number}" for kind, number in references(path.name)]
    refusal = authorize_unowned(store, path, generation, found)
    if refusal is not None:
        return _refused(store, generation, result, refusal)
    return _candidate(store, repositories, root, generation, path)


def _refused(
    store: LifecycleRegistry, generation: str, result: dict[str, object], reason: str,
) -> dict[str, object]:
    """Report a refusal, naming an authorization an earlier check left standing.

    A first check leaves admission open on refusal. A replay refusing after an
    earlier check authorized and closed admission (for example a crash before
    the retirement plan, then an edit) cannot undo it: admission never reopens,
    and the first event is never rewritten. That generation stays authorized,
    so a cleanup pass still retires it archive-first, preserving the edit; the
    flag says so instead of implying the tree is kept (GH#38417).
    """
    refused = dict(result, status="reclaim-refused", reason=reason)
    if unowned_authorized(store, generation):
        refused["standing_authorization"] = True
    return refused
