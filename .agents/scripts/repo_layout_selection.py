# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Explicit source selection beyond discovery: registered and nested roots."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from repo_layout_common import MigrationError, expand_path, git


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
