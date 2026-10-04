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


def manifest_record(
    path: Path,
    root: Path,
    ecosystem: str,
    direct: set[str],
    dev: set[str] | None = None,
) -> dict[str, Any]:
    # Dev-only names: declared only for development/build, never at runtime.
    # A name declared in both sections counts as runtime.
    # "locked" starts at 0; repo_metrics_dependencies.py fills it from lockfiles.
    dev_only = sorted((dev or set()) & direct)
    return {
        "path": path.relative_to(root).as_posix(),
        "ecosystem": ecosystem,
        "direct": len(direct),
        "runtime": len(direct) - len(dev_only),
        "dev": len(dev_only),
        "locked": 0,
        "dependencies": sorted(direct),
        "dev_dependencies": dev_only,
    }


def split_sections(
    data: Any,
    runtime_keys: tuple[str, ...],
    dev_keys: tuple[str, ...],
    skip: Callable[[str], bool] = lambda _name: False,
) -> tuple[set[str], set[str]]:
    """Return (all direct names, dev-only names) from manifest sections."""
    runtime: set[str] = set()
    dev: set[str] = set()
    if not isinstance(data, dict):
        return set(), set()
    for keys, target in ((runtime_keys, runtime), (dev_keys, dev)):
        for key in keys:
            deps = data.get(key)
            if isinstance(deps, dict):
                target.update(str(name) for name in deps.keys() if not skip(str(name)))
    return runtime | dev, dev - runtime
