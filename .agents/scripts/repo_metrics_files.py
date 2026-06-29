#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository file discovery for repo_metrics.py."""

from __future__ import annotations

import fnmatch
import os
from pathlib import Path
from typing import Iterable

from repo_metrics_git import run_command


def is_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            sample = handle.read(4096)
        return b"\0" in sample
    except OSError:
        return True


def should_exclude(rel: str, excludes: Iterable[str]) -> bool:
    rel_posix = rel.replace(os.sep, "/")
    parts = rel_posix.split("/")
    for pattern in excludes:
        clean = pattern.strip().strip("/")
        if not clean:
            continue
        if clean in parts:
            return True
        if rel_posix == clean or rel_posix.startswith(f"{clean}/"):
            return True
        if (
            fnmatch.fnmatch(rel_posix, clean)
            or fnmatch.fnmatch(rel_posix, pattern)
            or fnmatch.fnmatch(parts[-1], clean)
            or fnmatch.fnmatch(parts[-1], pattern)
        ):
            return True
    return False


def scan_prefixes(root: Path, paths: list[Path]) -> list[str]:
    prefixes: list[str] = []
    for scan_path in paths:
        resolved = scan_path.resolve()
        try:
            rel = resolved.relative_to(root)
        except ValueError:
            continue
        rel_s = rel.as_posix()
        if rel_s == ".":
            continue
        prefixes.append(rel_s)
    return prefixes


def matches_prefix(rel: str, prefixes: list[str]) -> bool:
    if not prefixes:
        return True
    for prefix in prefixes:
        if rel == prefix or rel.startswith(f"{prefix}/"):
            return True
    return False


def git_repo_relpaths(root: Path) -> list[str]:
    proc = run_command(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    if proc and proc.returncode == 0:
        return [part for part in proc.stdout.split("\0") if part]
    return []


def walk_repo_relpaths(root: Path, excludes: Iterable[str]) -> list[str]:
    rels: list[str] = []
    for walk_root, dirnames, filenames in os.walk(root):
        walk_path = Path(walk_root)
        rel_dir = walk_path.relative_to(root).as_posix() if walk_path != root else ""
        dirnames[:] = [
            item
            for item in dirnames
            if not should_exclude(f"{rel_dir}/{item}".strip("/"), excludes)
        ]
        rels.extend((walk_path / filename).relative_to(root).as_posix() for filename in filenames)
    return rels


def repo_relpaths(root: Path, excludes: Iterable[str]) -> list[str]:
    rels = git_repo_relpaths(root)
    return rels if rels else walk_repo_relpaths(root, excludes)


def is_countable_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not is_binary(path)


def list_repo_files(root: Path, paths: list[Path], excludes: Iterable[str]) -> list[Path]:
    prefixes = scan_prefixes(root, paths)
    rels = repo_relpaths(root, excludes)

    files: list[Path] = []
    seen: set[str] = set()
    for rel in rels:
        if rel in seen or should_exclude(rel, excludes) or not matches_prefix(rel, prefixes):
            continue
        seen.add(rel)
        path = root / rel
        if is_countable_file(path):
            files.append(path)
    return files
