#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dependency lockfile parsers for repo_metrics.py."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from repo_metrics_dependency_common import load_json


def parse_package_lock(path: Path) -> tuple[int, set[str]]:
    data = load_json(path)
    locked: set[str] = set()
    if isinstance(data, dict) and isinstance(data.get("packages"), dict):
        for key in data["packages"].keys():
            if isinstance(key, str) and key.startswith("node_modules/"):
                locked.add(key.removeprefix("node_modules/"))
    return len(locked), {f"npm:{name}" for name in locked}


def parse_cargo_lock(path: Path) -> tuple[int, set[str]]:
    names: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return 0, set()
    for line in lines:
        match = re.match(r'name\s*=\s*"([^"]+)"', line.strip())
        if match:
            names.add(match.group(1))
    return len(names), {f"cargo:{name}" for name in names}


def composer_lock_packages(data: Any) -> list[Any]:
    if not isinstance(data, dict):
        return []

    packages: list[Any] = []
    for key in ("packages", "packages-dev"):
        value = data.get(key)
        if isinstance(value, list):
            packages.extend(value)
    return packages


def composer_package_name(package: Any) -> str:
    if isinstance(package, dict) and package.get("name"):
        return str(package["name"])
    return ""


def parse_composer_lock(path: Path) -> tuple[int, set[str]]:
    data = load_json(path)
    names: set[str] = set()
    for package in composer_lock_packages(data):
        name = composer_package_name(package)
        if name:
            names.add(name)
    return len(names), {f"composer:{name}" for name in names}


def parse_gemfile_lock(path: Path) -> tuple[int, set[str]]:
    names: set[str] = set()
    in_specs = False
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return 0, set()
    for line in lines:
        if line.strip() and not line.startswith(" "):
            in_specs = False
        if line.strip() == "specs:":
            in_specs = True
            continue
        if in_specs:
            match = re.match(r"\s{4}([A-Za-z0-9_.-]+)\s", line)
            if match:
                names.add(match.group(1))
    return len(names), {f"bundler:{name}" for name in names}
