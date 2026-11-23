# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Explicit source selection beyond discovery: registered and nested roots."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from repo_layout_common import MigrationError, expand_path, git


def tracked_by_parent(source: Path) -> bool:
    """Return whether an enclosing repository tracks source or any path below it.

    This covers submodule gitlinks and ordinary files the parent indexes inside
    the nested checkout; moving the source would delete either from the parent.
    """
    try:
        parent_root = expand_path(git(source.parent, "rev-parse", "--show-toplevel").strip())
    except MigrationError:
        return False
    relative = source.relative_to(parent_root.resolve()).as_posix()
    return bool(git(parent_root, "ls-files", "--stage", "--", f":(literal){relative}").strip())


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
    if tracked_by_parent(source):
        raise MigrationError("Selected source is tracked by its parent repository")


def nested_first_order(sources: list[Path]) -> list[Path]:
    """Order each source before every selected source that contains it.

    Apply moves repositories in plan order and rollback reverses it, so a
    nested repository leaves before its parent and returns after it.
    """
    def containers(path: Path) -> int:
        return sum(1 for other in sources if other != path and path.is_relative_to(other))

    return sorted(sources, key=lambda path: -containers(path))


def validate_disjoint_destinations(destinations: list[Path]) -> None:
    """Refuse planned destinations that are equal or contain one another.

    Moving into a path below another planned destination would create that
    destination first, leaving the later move ambiguous and unrollbackable.
    """
    for index, first in enumerate(destinations):
        for second in destinations[index + 1 :]:
            if first.is_relative_to(second) or second.is_relative_to(first):
                raise MigrationError(f"Planned destinations overlap: {first} and {second}")


def nested_relative_paths(parent: Path, sources: list[Path]) -> tuple[str, ...]:
    """Return selected sources nested inside parent, relative to it."""
    return tuple(
        sorted(
            child.relative_to(parent).as_posix()
            for child in sources
            if child != parent and child.is_relative_to(parent)
        )
    )
