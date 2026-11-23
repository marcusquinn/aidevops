# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only repository discovery, identity and preservation fingerprints."""

from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path
from typing import Any

from repo_layout_common import (
    MigrationError,
    canonical_bytes,
    expand_path,
    file_sha256,
    git,
    run,
    sha256_bytes,
)


REMOTE_RE = re.compile(
    r"^(?:(?:[a-z][a-z0-9+.-]*://)(?:[^/@]+@)?|[^@/]+@)?"
    r"(?P<host>[^/:]+)[:/](?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$",
    re.IGNORECASE,
)


def parse_remote(remote: str) -> tuple[str, str, str] | None:
    """Return sanitized host/owner/repository identity for a Git remote."""
    match = REMOTE_RE.match(remote.strip())
    if not match:
        return None
    host = match.group("host").lower()
    owner = match.group("owner")
    repository = match.group("repo")
    if not all(re.fullmatch(r"[A-Za-z0-9._-]+", item) for item in (host, owner, repository)):
        return None
    return host, owner, repository


def discover_repositories(workspace: Path, discovery_lib: Path) -> list[Path]:
    """Call the shared bounded shell discovery policy and parse NUL records."""
    script = 'source "$1"; aidevops_discover_canonical_repos "$2"'
    output = run(
        ["bash", "-c", script, "repo-layout-discovery", str(discovery_lib), str(workspace)],
        binary=True,
    )
    return sorted(Path(item.decode()) for item in output.split(b"\0") if item)


def tracked_as_gitlink(source: Path) -> bool:
    """Return whether an enclosing repository records source as a submodule."""
    try:
        parent_root = expand_path(git(source.parent, "rev-parse", "--show-toplevel").strip())
    except MigrationError:
        return False
    relative = source.relative_to(parent_root.resolve()).as_posix()
    records = git(parent_root, "ls-files", "--stage", "--", f":(literal){relative}")
    return any(line.startswith("160000 ") for line in records.splitlines())


def validate_registered_source(
    source: Path, workspace: Path, registrations: list[dict[str, Any]]
) -> None:
    """Accept an undiscovered source only as an exact registered canonical root.

    Discovery stays bounded to top-level workspace repositories. An explicit
    source outside it (another directory, or nested in a repository) needs an
    approved repos.json registration, its own .git directory, and no local-only
    or submodule role, so selection cannot widen to arbitrary directories.
    """
    matches = [
        item
        for item in registrations
        if isinstance(item.get("path"), str) and expand_path(item["path"]) == source
    ]
    if not matches:
        raise MigrationError("Selected source is not a discovered or registered repository")
    if any(item.get("local_only") is True for item in matches):
        raise MigrationError("Selected source is a local-only registration")
    if workspace.is_relative_to(source):
        raise MigrationError("Selected source must not contain the workspace")
    marker = source / ".git"
    if marker.is_symlink() or not marker.is_dir():
        raise MigrationError("Selected source is not a canonical repository root")
    top_level = expand_path(git(source, "rev-parse", "--show-toplevel").strip())
    if top_level.resolve() != source:
        raise MigrationError("Selected source is not a canonical repository root")
    if tracked_as_gitlink(source):
        raise MigrationError("Selected source is a submodule of its parent repository")


def nested_first_order(sources: list[Path]) -> list[Path]:
    """Order each source before every selected source that contains it.

    Apply moves repositories in plan order and rollback reverses it, so a
    nested repository leaves before its parent and returns after it.
    """
    def containers(path: Path) -> int:
        return sum(1 for other in sources if other != path and path.is_relative_to(other))

    return sorted(sources, key=lambda path: -containers(path))


def nested_relative_paths(parent: Path, sources: list[Path]) -> tuple[str, ...]:
    """Return selected sources nested inside parent, relative to it."""
    return tuple(
        sorted(
            child.relative_to(parent).as_posix()
            for child in sources
            if child != parent and child.is_relative_to(parent)
        )
    )


def recommended_path(
    workspace: Path,
    identity: tuple[str, str, str],
    repos_json: Path,
    discovery_lib: Path,
) -> Path:
    """Call the shared host-aware owner path policy."""
    host, owner, repository = identity
    script = 'source "$1"; aidevops_recommended_repo_path "$2" "$3" "$4" "$5" "$6"'
    output = run(
        [
            "bash",
            "-c",
            script,
            "repo-layout-recommend",
            str(discovery_lib),
            str(workspace),
            host,
            owner,
            repository,
            str(repos_json),
        ]
    )
    return expand_path(output.strip())


def excluded_pathspec(excluded: tuple[str, ...]) -> list[str]:
    """Omit nested repositories that migrate separately from a parent's state.

    An empty exclusion keeps the exact historical Git invocation so digests in
    existing plans remain comparable.
    """
    if not excluded:
        return []
    return ["--", ".", *(f":(exclude,literal){item}" for item in excluded)]


def status_records(repo: Path, excluded: tuple[str, ...] = ()) -> tuple[str, int]:
    """Return a stable status digest and entry count."""
    raw = git(
        repo,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        *excluded_pathspec(excluded),
        binary=True,
    )
    return sha256_bytes(raw), len([item for item in raw.split(b"\0") if item])


def working_tree_digest(repo: Path, excluded: tuple[str, ...] = ()) -> str:
    """Hash tracked diffs and exact untracked file content."""
    digest = hashlib.sha256()
    digest.update(git(repo, "diff", "--no-ext-diff", "--binary", binary=True))
    digest.update(
        git(repo, "diff", "--cached", "--no-ext-diff", "--binary", binary=True)
    )
    untracked = git(
        repo,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        *excluded_pathspec(excluded),
        binary=True,
    )
    for raw_path in sorted(item for item in untracked.split(b"\0") if item):
        digest.update(raw_path)
        path = repo / os.fsdecode(raw_path)
        if path.is_symlink():
            digest.update(b"symlink\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(b"file\0" + path.read_bytes())
        else:
            raise MigrationError(f"Unsupported untracked path: {path}")
    return digest.hexdigest()


def worktree_records(repo: Path, excluded: tuple[str, ...] = ()) -> list[dict[str, Any]]:
    """Return normalized worktree identities, preserving linked paths.

    ``excluded`` applies only to the main worktree, which is the checkout that
    contains nested repositories selected for the same migration.
    """
    records: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if current:
                path = Path(current.get("worktree", ""))
                if path.is_dir():
                    omitted = () if records else excluded
                    status_hash, status_count = status_records(path, omitted)
                    current["status_sha256"] = status_hash
                    current["status_entries"] = status_count
                    current["working_tree_sha256"] = working_tree_digest(path, omitted)
                # Git always lists the main worktree first. Normalize that
                # location because its spelling changes during a move.
                current["worktree"] = "<canonical>" if not records else str(path)
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return records


def repository_fingerprint(repo: Path, excluded: tuple[str, ...] = ()) -> dict[str, Any]:
    """Capture the exact local Git state that a move must preserve.

    ``excluded`` names repository-relative nested repositories that the same
    plan moves first, so their departure is not reported as parent drift.
    """
    status_hash, status_count = status_records(repo, excluded)
    branches = git(
        repo,
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%00%(objectname)",
        "refs/heads",
    ).splitlines()
    stashes = git(
        repo,
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%00%(objectname)",
        "refs/stash",
    ).splitlines()
    gitmodules = repo / ".gitmodules"
    modules_hash = file_sha256(gitmodules) if gitmodules.exists() else None
    submodule_state: list[dict[str, str]] = []
    index_records = git(repo, "ls-files", "--stage", "-z", binary=True)
    for record in index_records.split(b"\0"):
        if not record:
            continue
        metadata, _, raw_path = record.partition(b"\t")
        mode, object_name, _stage = metadata.decode().split(" ", 2)
        if mode != "160000":
            continue
        relative_path = raw_path.decode()
        child = repo / relative_path
        actual_head = "unavailable"
        if child.exists():
            try:
                actual_head = git(child, "rev-parse", "HEAD").strip()
            except MigrationError:
                actual_head = "unavailable"
        submodule_state.append(
            {
                "path": relative_path,
                "index_head": object_name,
                "actual_head": actual_head,
                "working_tree_sha256": (
                    working_tree_digest(child)
                    if child.exists() and actual_head != "unavailable"
                    else "unavailable"
                ),
            }
        )
    return {
        "head": git(repo, "rev-parse", "HEAD").strip(),
        "branch": git(repo, "symbolic-ref", "--quiet", "--short", "HEAD").strip(),
        "branches": branches,
        "status_sha256": status_hash,
        "status_entries": status_count,
        "working_tree_sha256": working_tree_digest(repo, excluded),
        "stashes": stashes,
        "stash_count": len(stashes),
        "gitmodules_sha256": modules_hash,
        "submodules_sha256": sha256_bytes(canonical_bytes(submodule_state)),
        "worktrees": worktree_records(repo, excluded),
    }


def prunable_worktree_paths(records: list[dict[str, Any]]) -> list[str]:
    """Return linked registrations Git marks prunable whose path is absent.

    Such entries are dead metadata with no pointer to repair (GH#40058). Any
    other missing or unexpected pointer stays fail-closed.
    """
    return [
        str(record["worktree"])
        for record in records
        if record.get("worktree") not in (None, "", "<canonical>")
        and "prunable" in record
        and not os.path.lexists(record["worktree"])
    ]


def linked_pointer_records(repo: Path, records: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Record exact linked-worktree pointer content for guarded repair."""
    pointers: list[dict[str, str]] = []
    prefix = f"gitdir: {repo}/.git/"
    prunable = set(prunable_worktree_paths(records))
    for record in records:
        worktree = record.get("worktree")
        if not worktree or worktree == "<canonical>" or worktree in prunable:
            continue
        marker = Path(worktree) / ".git"
        if marker.is_symlink() or not marker.is_file():
            raise MigrationError(f"Linked worktree pointer is unavailable: {marker}")
        content = marker.read_text(encoding="utf-8")
        if not content.startswith(prefix):
            raise MigrationError(f"Unexpected linked worktree pointer: {marker}")
        pointers.append(
            {"path": str(marker), "sha256": sha256_bytes(content.encode()), "content": content}
        )
    return pointers
