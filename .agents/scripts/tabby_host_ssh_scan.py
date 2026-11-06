# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Conservative read-only discovery of conflicting user-owned SSH aliases."""

import fnmatch
import glob
import shlex
from pathlib import Path

from tabby_host_files import snapshot
from tabby_session_config import SessionError


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


def included_paths(values):
    for value in values:
        if "%" in value or "$" in value:
            raise SessionError("Dynamic SSH Includes require manual configuration; refusing SSH changes")
        pattern = Path(value).expanduser()
        if not pattern.is_absolute():
            pattern = Path.home() / ".ssh" / pattern
        for match in glob.glob(str(pattern)):
            yield Path(match).absolute()


def conflicts(path, alias, managed, seen=None):
    """Follow local Includes without running commands; preserve unmanaged blocks."""
    seen = set() if seen is None else seen
    if path == managed or path in seen:
        return False
    if len(seen) > 100:
        raise SessionError("Too many SSH Includes to check safely")
    seen.add(path)
    raw = snapshot(path)
    if raw is None:
        return False
    for key, values in directives(raw):
        # Conditional rules may depend on canonicalization, the new endpoint,
        # or exec output. Do not execute or guess them when taking ownership.
        if key == "match" and [v.lower() for v in values] != ["all"]:
            raise SessionError("Conditional SSH Match blocks require manual configuration; refusing SSH changes")
        if key == "host" and matches_host(values, alias):
            return True
        if key == "include" and any(conflicts(p, alias, managed, seen) for p in included_paths(values)):
            return True
    return False
