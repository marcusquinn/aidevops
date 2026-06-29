#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared dependency parser utilities for repo_metrics.py."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable

try:  # Python 3.11+
    import tomllib  # type: ignore[attr-defined]
except Exception:  # pragma: no cover - Python <3.11 fallback
    tomllib = None  # type: ignore[assignment]

ManifestParseResult = tuple[dict[str, Any] | None, set[str], set[str]]
ManifestParser = Callable[[Path, Path], ManifestParseResult]
LockParser = Callable[[Path], tuple[int, set[str]]]


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_toml(path: Path) -> dict[str, Any]:
    if tomllib is None:
        return {}
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def normalise_dep_name(value: str) -> str:
    value = value.strip().strip('"\'')
    if not value or value.startswith(("#", "-r ", "--", "git+", "http://", "https://")):
        return ""
    if value.startswith("@"):
        parts = value.split("/")
        if len(parts) >= 2:
            return f"{parts[0]}/{re.split(r'[\s@<>=~!;]', parts[1], maxsplit=1)[0]}"
    match = re.match(r"([A-Za-z0-9_][A-Za-z0-9_.-]*)", value)
    return match.group(1) if match else ""


def manifest_record(path: Path, root: Path, ecosystem: str, direct: set[str], locked: int = 0) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "ecosystem": ecosystem,
        "direct": len(direct),
        "locked": locked,
        "dependencies": sorted(direct),
    }
