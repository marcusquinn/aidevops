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


def status_records(repo: Path) -> tuple[str, int]:
    """Return a stable status digest and entry count."""
    raw = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", binary=True)
    return sha256_bytes(raw), len([item for item in raw.split(b"\0") if item])


def working_tree_digest(repo: Path) -> str:
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


def worktree_records(repo: Path) -> list[dict[str, Any]]:
    """Return normalized worktree identities, preserving linked paths."""
    records: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if current:
                path = Path(current.get("worktree", ""))
                if path.is_dir():
                    status_hash, status_count = status_records(path)
                    current["status_sha256"] = status_hash
                    current["status_entries"] = status_count
                    current["working_tree_sha256"] = working_tree_digest(path)
                # Git always lists the main worktree first. Normalize that
                # location because its spelling changes during a move.
                current["worktree"] = "<canonical>" if not records else str(path)
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return records


def repository_fingerprint(repo: Path) -> dict[str, Any]:
    """Capture the exact local Git state that a move must preserve."""
    status_hash, status_count = status_records(repo)
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
        "working_tree_sha256": working_tree_digest(repo),
        "stashes": stashes,
        "stash_count": len(stashes),
        "gitmodules_sha256": modules_hash,
        "submodules_sha256": sha256_bytes(canonical_bytes(submodule_state)),
        "worktrees": worktree_records(repo),
    }


def linked_pointer_records(repo: Path, records: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Record exact linked-worktree pointer content for guarded repair."""
    pointers: list[dict[str, str]] = []
    prefix = f"gitdir: {repo}/.git/"
    for record in records:
        worktree = record.get("worktree")
        if not worktree or worktree == "<canonical>":
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
