#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Go dependency manifest parser for repo_metrics.py."""

from __future__ import annotations

from pathlib import Path

from repo_metrics_dependency_common import ManifestParseResult, manifest_record


def go_require_block_state(line: str, in_block: bool) -> tuple[bool, bool]:
    if line == "require (":
        return True, True
    if in_block and line == ")":
        return False, True
    return in_block, False


def go_require_name_from_line(line: str, in_block: bool) -> str:
    if line.startswith("require "):
        source = line.removeprefix("require ")
    elif in_block and line and not line.startswith("//"):
        source = line
    else:
        source = ""

    parts = source.split()
    return parts[0] if parts else ""


def parse_go_mod(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    in_block = False
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for raw in lines:
        line = raw.strip()
        in_block, handled = go_require_block_state(line, in_block)
        if handled:
            continue
        name = go_require_name_from_line(line, in_block)
        if name:
            direct.add(name)
    return manifest_record(path, root, "go", direct), {f"go:{name}" for name in direct}, set()
