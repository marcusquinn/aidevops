#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dependency aggregation for repo_metrics.py."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from repo_metrics_dependency_common import LockParser, ManifestParser, ManifestParseResult
from repo_metrics_dependency_locks import (
    parse_cargo_lock,
    parse_composer_lock,
    parse_gemfile_lock,
    parse_package_lock,
)
from repo_metrics_dependency_go import parse_go_mod
from repo_metrics_dependency_manifests import (
    parse_cargo_toml,
    parse_composer_json,
    parse_gemfile,
    parse_package_json,
)
from repo_metrics_dependency_python import parse_pyproject, parse_requirements

MANIFEST_PARSERS: dict[str, ManifestParser] = {
    "package.json": parse_package_json,
    "pyproject.toml": parse_pyproject,
    "go.mod": parse_go_mod,
    "Cargo.toml": parse_cargo_toml,
    "composer.json": parse_composer_json,
    "Gemfile": parse_gemfile,
}

LOCK_PARSERS: dict[str, tuple[str, LockParser]] = {
    "package-lock.json": ("npm", parse_package_lock),
    "Cargo.lock": ("cargo", parse_cargo_lock),
    "composer.lock": ("composer", parse_composer_lock),
    "Gemfile.lock": ("bundler", parse_gemfile_lock),
}


def manifest_parser_for(name: str) -> ManifestParser | None:
    if name.startswith("requirements") and name.endswith(".txt"):
        return parse_requirements
    return MANIFEST_PARSERS.get(name)


def parse_manifest_file(path: Path, root: Path) -> ManifestParseResult:
    parser = manifest_parser_for(path.name)
    if parser is None:
        return None, set(), set()
    return parser(path, root)


def parse_lock_file(path: Path) -> tuple[str, int, set[str]] | None:
    lock_parser = LOCK_PARSERS.get(path.name)
    if lock_parser is None:
        return None
    ecosystem, parser = lock_parser
    locked_count, locked = parser(path)
    return ecosystem, locked_count, locked


def dependency_file_order(root: Path, files: list[Path]) -> list[Path]:
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def apply_manifest_lock_counts(
    root: Path,
    manifests: list[dict[str, Any]],
    lock_counts_by_dir: dict[tuple[str, str], int],
) -> None:
    for record in manifests:
        manifest_path = root / record["path"]
        key = (str(manifest_path.parent), str(record["ecosystem"]))
        if key in lock_counts_by_dir:
            record["locked"] = max(int(record.get("locked", 0)), lock_counts_by_dir[key])


def dependency_summary(
    manifests: list[dict[str, Any]],
    direct_names: set[str],
    locked_names: set[str],
) -> dict[str, Any]:
    ecosystems = sorted({str(record["ecosystem"]) for record in manifests})
    direct_count = len(direct_names)
    locked_count = len(locked_names)
    return {
        "direct": direct_count,
        "locked": locked_count,
        "total": max(direct_count, locked_count),
        "ecosystems": ecosystems,
        "manifests": manifests,
    }


def collect_dependencies(root: Path, files: list[Path]) -> dict[str, Any]:
    manifests: list[dict[str, Any]] = []
    direct_names: set[str] = set()
    locked_names: set[str] = set()
    lock_counts_by_dir: dict[tuple[str, str], int] = {}

    for path in dependency_file_order(root, files):
        record, direct, locked = parse_manifest_file(path, root)
        if record is not None:
            manifests.append(record)
            direct_names.update(direct)
            locked_names.update(locked)

        lock_result = parse_lock_file(path)
        if lock_result is not None:
            ecosystem, locked_count, locked = lock_result
            lock_counts_by_dir[(str(path.parent), ecosystem)] = locked_count
            locked_names.update(locked)

    apply_manifest_lock_counts(root, manifests, lock_counts_by_dir)
    return dependency_summary(manifests, direct_names, locked_names)
