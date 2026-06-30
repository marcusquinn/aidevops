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
)


def parse_package_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    if not isinstance(data, dict):
        return None, set(), set()
    direct: set[str] = set()
    for key in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        deps = data.get(key)
        if isinstance(deps, dict):
            direct.update(str(name) for name in deps.keys())
    return manifest_record(path, root, "npm", direct), {f"npm:{name}" for name in direct}, set()


def parse_cargo_toml(path: Path, root: Path) -> ManifestParseResult:
    data = load_toml(path)
    direct: set[str] = set()
    for key in ("dependencies", "dev-dependencies", "build-dependencies"):
        deps = data.get(key, {}) if isinstance(data, dict) else {}
        if isinstance(deps, dict):
            direct.update(str(name) for name in deps.keys())
    return manifest_record(path, root, "cargo", direct), {f"cargo:{name}" for name in direct}, set()


def parse_composer_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    direct: set[str] = set()
    if isinstance(data, dict):
        for key in ("require", "require-dev"):
            deps = data.get(key)
            if isinstance(deps, dict):
                direct.update(str(name) for name in deps.keys() if str(name).lower() != "php")
    return manifest_record(path, root, "composer", direct), {f"composer:{name}" for name in direct}, set()


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
