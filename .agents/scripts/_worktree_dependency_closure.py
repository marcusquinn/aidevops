# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Dependency closure validation for pnpm-store packages."""

import os
import re

from _worktree_dependency_identity import Rejected, object_json, regular_bytes

DEPENDENCY_NAME = re.compile(r"(?:@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]+")


def _linked_dependency(siblings, dependency, boundary):
    if not DEPENDENCY_NAME.fullmatch(dependency):
        raise Rejected("invalid-dependency-name")
    link = siblings / dependency
    if not os.path.lexists(link):
        raise Rejected("incomplete-package-inventory")
    try:
        resolved = link.resolve(strict=True)
    except (FileNotFoundError, NotADirectoryError):
        raise Rejected("dangling-dependency-link") from None
    if not resolved.is_relative_to(boundary):
        raise Rejected("escaping-package-root")
    return resolved


def check_closure(package_dir, visited, boundary):
    """Require each non-optional dependency of a pnpm-store package to be linked."""
    if package_dir in visited or ".pnpm" not in package_dir.parts:
        return
    visited.add(package_dir)
    manifest = object_json(regular_bytes(package_dir / "package.json"))
    name = manifest.get("name")
    if not isinstance(name, str):
        raise Rejected("incomplete-package-inventory")
    siblings = package_dir.parents[name.count("/")]
    required = set(manifest.get("dependencies", {}))
    required -= set(manifest.get("optionalDependencies", {}))
    for dependency in sorted(required):
        check_closure(_linked_dependency(siblings, dependency, boundary), visited, boundary)
