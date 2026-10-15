#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded reference scanning for credential names (GH#34719).

Classifies lines as a literal use of a secret name (token-exact) or a
possible dynamic construction (`PREFIX_${X}_TAIL`, concatenation, f-strings,
`%s`/`.format`). Matched line text is used only for classification and is
never returned, so values that happen to sit in scanned files never leak.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess  # nosec B404 -- absolute git/crontab, list argv, never a shell
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from xml.parsers.expat import ExpatError

MAX_HITS = 500
MAX_FILE_BYTES = 1_000_000
MAX_TREE_FILES = 5000
MAX_GAP = 80
TOKEN_RE = re.compile(r"[A-Za-z0-9_]")
DYNAMIC_RE = re.compile(r"\$\{|\$\(|\$[A-Za-z_]|[\"']\s*\+|\+\s*[\"']|%s|\{[A-Za-z_][\w.]*\}|\.format\(|\.join\(")
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv"}


@dataclass(frozen=True)
class Needles:
    """Exact names plus (prefix, tail) stems for dynamic-construction checks."""

    names: tuple[str, ...]
    stems: tuple[tuple[str, str], ...]

    @property
    def patterns(self) -> list[str]:
        """Fixed strings for a first-pass grep; every name contains its prefix."""
        return sorted({prefix for prefix, _ in self.stems} | set(self.names))


def build_needles(names: Iterable[str]) -> Needles:
    """Build needles from a secret name and its aliases."""
    unique = sorted(set(names))
    stems = {(parts[0], parts[-1]) for parts in (name.split("_") for name in unique) if len(parts) >= 2}
    return Needles(tuple(unique), tuple(sorted(stems)))


def has_token(line: str, name: str) -> bool:
    """True when `name` appears with no identifier characters either side."""
    start = line.find(name)
    while start >= 0:
        end = start + len(name)
        before = line[start - 1] if start else ""
        after = line[end] if end < len(line) else ""
        if not TOKEN_RE.match(before) and not TOKEN_RE.match(after):
            return True
        start = line.find(name, start + 1)
    return False


def looks_dynamic(line: str, prefix: str, tail: str) -> bool:
    """True when prefix..tail on one expression is joined by a dynamic part."""
    start = line.find(prefix)
    while start >= 0:
        gap_start = start + len(prefix)
        end = line.find(tail, gap_start)
        gap = line[gap_start:end] if end >= 0 else ""
        if 0 < len(gap) <= MAX_GAP and prefix not in gap and not set(gap) & {";", "="} and DYNAMIC_RE.search(gap):
            return True
        start = line.find(prefix, start + 1)
    return False


def classify(line: str, needles: Needles) -> tuple[str, str] | None:
    """Return ("literal", NAME), ("possible-dynamic", PATTERN) or None."""
    for name in needles.names:
        if has_token(line, name):
            return "literal", name
    for prefix, tail in needles.stems:
        if looks_dynamic(line, prefix, tail):
            return "possible-dynamic", f"{prefix}_*_{tail}"
    return None


def scan_lines(lines: Iterable[str], needles: Needles) -> list[dict]:
    """Classify numbered lines; returns path-less hit records."""
    hits = []
    for number, line in enumerate(lines, 1):
        hit = classify(line, needles)
        if hit:
            hits.append({"line": number, "kind": hit[0], "matched": hit[1]})
    return hits


def run_tool(tool: str, args: list[str], timeout: int) -> subprocess.CompletedProcess:
    """Run a fixed system tool by absolute path; FileNotFoundError if absent."""
    executable = shutil.which(tool)
    if not executable:
        raise FileNotFoundError(tool)
    # Absolute executable, list argv (no shell); args are paths and fixed-string needles.
    return subprocess.run(  # nosec B603
        [executable, *args], capture_output=True, text=True, errors="replace", timeout=timeout, check=False,
    )


def grep_worktree(path: Path, needles: Needles, timeout: int) -> tuple[list[dict], str | None]:
    """git grep a worktree (tracked + untracked, honouring .gitignore)."""
    args = ["-C", str(path), "grep", "-I", "-n", "--null", "--untracked", "-F"]
    for pattern in needles.patterns:
        args += ["-e", pattern]
    try:
        result = run_tool("git", args, timeout)
    except subprocess.TimeoutExpired:
        return [], "timeout"
    except OSError:
        return [], "git unavailable"
    if result.returncode not in (0, 1):
        return [], "git grep failed"
    hits: list[dict] = []
    for raw in result.stdout.splitlines():
        parts = raw.split("\0", 2)
        hit = classify(parts[2], needles) if len(parts) == 3 and parts[1].isdigit() else None
        if hit:
            hits.append({"path": parts[0], "line": int(parts[1]), "kind": hit[0], "matched": hit[1]})
        if len(hits) >= MAX_HITS:
            return hits, "truncated"
    return hits, None


def plist_as_xml(data: bytes) -> str | None:
    """XML text for a parseable plist, or None so callers fall back to raw text."""
    try:
        return plistlib.dumps(plistlib.loads(data), fmt=plistlib.FMT_XML).decode("utf-8", "replace")
    except (plistlib.InvalidFileException, ExpatError, ValueError, TypeError, OverflowError):
        return None


def read_text(path: Path) -> str | None:
    """Readable text (XML for binary plists); "" for binary, None if unscanned."""
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if path.suffix == ".plist":
        xml_text = plist_as_xml(data)
        if xml_text is not None:
            return xml_text
    if b"\0" in data[:4096]:
        return ""  # binary, skipped like `git grep -I`
    return data.decode("utf-8", "replace")


def scan_files(paths: Iterable[Path], needles: Needles) -> tuple[list[dict], list[str]]:
    """Scan explicit files; returns hits and paths skipped as unreadable/large."""
    hits: list[dict] = []
    skipped: list[str] = []
    for path in paths:
        text = read_text(path)
        if text is None:
            skipped.append(str(path))
            continue
        hits += [{"path": str(path), **hit} for hit in scan_lines(text.splitlines(), needles)]
    return hits, skipped


def tree_files(root: Path) -> tuple[list[Path], bool]:
    """Files under root (skipping VCS/dependency dirs); True if capped."""
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        found += [Path(dirpath) / name for name in filenames]
        if len(found) >= MAX_TREE_FILES:
            return found[:MAX_TREE_FILES], True
    return found, False
