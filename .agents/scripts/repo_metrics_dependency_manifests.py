#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dependency manifest parsers for repo_metrics.py."""

from __future__ import annotations

import re
from pathlib import Path

from repo_metrics_dependency_common import (
    ManifestParseResult,
    load_json,
    load_toml,
    manifest_record,
    split_sections,
)


def parse_package_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    if not isinstance(data, dict):
        return None, set(), set()
    direct, dev = split_sections(
        data, ("dependencies", "optionalDependencies", "peerDependencies"), ("devDependencies",)
    )
    return manifest_record(path, root, "npm", direct, dev=dev), {f"npm:{name}" for name in direct}, set()


def parse_cargo_toml(path: Path, root: Path) -> ManifestParseResult:
    data = load_toml(path)
    direct, dev = split_sections(data, ("dependencies",), ("dev-dependencies", "build-dependencies"))
    return manifest_record(path, root, "cargo", direct, dev=dev), {f"cargo:{name}" for name in direct}, set()


def _composer_platform_package(name: str) -> bool:
    # php, ext-*, lib-*, composer-* are platform requirements, not packages.
    lowered = name.lower()
    return lowered == "php" or lowered.startswith(("php-", "ext-", "lib-", "composer-"))


def parse_composer_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    direct, dev = split_sections(data, ("require",), ("require-dev",), skip=_composer_platform_package)
    return manifest_record(path, root, "composer", direct, dev=dev), {f"composer:{name}" for name in direct}, set()


def parse_gemfile(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for line in lines:
        match = re.match(r"\s*gem\s+['\"]([^'\"]+)['\"]", line)
        if match:
            direct.add(match.group(1))
    return manifest_record(path, root, "bundler", direct), {f"bundler:{name}" for name in direct}, set()
