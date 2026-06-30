#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Python dependency manifest parsers for repo_metrics.py."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Iterable

from repo_metrics_dependency_common import (
    ManifestParseResult,
    load_toml,
    manifest_record,
    normalise_dep_name,
)


def normalised_names(values: Iterable[Any]) -> set[str]:
    names: set[str] = set()
    for value in values:
        name = normalise_dep_name(str(value))
        if name:
            names.add(name)
    return names


def parse_requirements(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for raw in lines:
        name = normalise_dep_name(raw.split(";", 1)[0])
        if name:
            direct.add(name)
    return manifest_record(path, root, "python", direct), {f"python:{name}" for name in direct}, set()


def pyproject_project_dependencies(project: Any) -> set[str]:
    direct: set[str] = set()
    if not isinstance(project, dict):
        return direct

    deps = project.get("dependencies", [])
    if isinstance(deps, list):
        direct.update(normalised_names(deps))

    optional = project.get("optional-dependencies", {})
    if isinstance(optional, dict):
        for group in optional.values():
            if isinstance(group, list):
                direct.update(normalised_names(group))
    return direct


def pyproject_poetry_dependencies(data: dict[str, Any]) -> set[str]:
    tool = data.get("tool", {})
    poetry = tool.get("poetry", {}) if isinstance(tool, dict) else {}
    poetry_deps = poetry.get("dependencies", {}) if isinstance(poetry, dict) else {}
    if isinstance(poetry_deps, dict):
        return {str(name) for name in poetry_deps.keys() if str(name).lower() != "python"}
    return set()


def parse_pyproject(path: Path, root: Path) -> ManifestParseResult:
    data = load_toml(path)
    project = data.get("project", {}) if isinstance(data, dict) else {}
    direct = pyproject_project_dependencies(project)
    direct.update(pyproject_poetry_dependencies(data))
    return manifest_record(path, root, "python", direct), {f"python:{name}" for name in direct}, set()
