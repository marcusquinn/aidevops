# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conservative read-only discovery of conflicting unmanaged SSH aliases."""

import fnmatch
import glob
import os
import shlex
import stat
from pathlib import Path

from tabby_session_config import SessionError


def scan_snapshot(path):
    """Read user- or root-owned config without relaxing write-target checks."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise SessionError("Configuration paths must not contain symlinks")
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()) or info.st_nlink != 1:
        raise SessionError("SSH configuration must be a user- or root-owned regular file without hard links")
    if info.st_mode & 0o022:
        raise SessionError("Configuration must not be writable by other accounts")
    return path.read_bytes()


def directives(raw):
    """Normalize OpenSSH's whitespace and equals forms before inspection."""
    try:
        for line in raw.decode().splitlines():
            tokens = shlex.split(line, comments=True)
            if not tokens:
                continue
            if "=" in tokens[0]:
                key, value = tokens[0].split("=", 1)
                tokens = [key, value, *tokens[1:]]
            key = tokens[0].lower()
            values = tokens[1:]
            if values and values[0] == "=":
                values = values[1:]
            elif values and values[0].startswith("="):
                values = [values[0][1:], *values[1:]]
            yield key, values
    except (UnicodeError, ValueError):
        raise SessionError("Cannot safely parse existing SSH configuration") from None


def matches_host(values, alias):
    alias = alias.lower()
    positives = [p for p in values if not p.startswith("!")]
    excluded = any(fnmatch.fnmatchcase(alias, p[1:].lower()) for p in values if p.startswith("!"))
    return not excluded and any(p != "*" and fnmatch.fnmatchcase(alias, p.lower()) for p in positives)


def included_paths(values, include_base):
    for value in values:
        if "%" in value or "$" in value:
            raise SessionError("Dynamic SSH Includes require manual configuration; refusing SSH changes")
        pattern = Path(value).expanduser()
        if not pattern.is_absolute():
            pattern = include_base / pattern
        for match in sorted(glob.glob(str(pattern))):
            yield Path(match).absolute()


def conflicts(path, alias, managed, seen=None, include_base=None):
    """Follow local Includes without running commands; preserve unmanaged blocks."""
    seen = set() if seen is None else seen
    include_base = Path.home() / ".ssh" if include_base is None else include_base
    if path == managed or path in seen:
        return False
    if len(seen) > 100:
        raise SessionError("Too many SSH Includes to check safely")
    seen.add(path)
    raw = scan_snapshot(path)
    if raw is None:
        return False
    for key, values in directives(raw):
        # Conditional rules may depend on canonicalization, the new endpoint,
        # or exec output. Do not execute or guess them when taking ownership.
        if key == "match" and [v.lower() for v in values] != ["all"]:
            raise SessionError("Conditional SSH Match blocks require manual configuration; refusing SSH changes")
        if key == "host" and matches_host(values, alias):
            return True
        if key == "include" and any(conflicts(p, alias, managed, seen, include_base)
                                    for p in included_paths(values, include_base)):
            return True
    return False
