# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Moved shell-function detection for file-split-verify.py."""

import collections
import re

SHELL_SUFFIXES = (".sh", ".bash", ".zsh")
FUNC_DEF_RES = (
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_:.-]*)\s*(?:\(\s*\))?\s*(?:\{.*)?$"),
    re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\s*\)\s*(?:\{.*)?$"),
)


def _function_name(content):
    """Return the shell function name defined on a line, or None."""
    for pattern in FUNC_DEF_RES:
        match = pattern.match(content)
        if match:
            return match.group(1)
    return None


def function_defs(entries):
    """Map shell path -> set of function names defined in the entries."""
    defs = collections.defaultdict(set)
    for path, _line_no, content in entries:
        if path and path.endswith(SHELL_SUFFIXES):
            name = _function_name(content)
            if name:
                defs[path].add(name)
    return defs


def moved_functions(removed, added):
    """Return sorted (fn, old_path, new_path) for cross-file moves."""
    removed_defs, added_defs = function_defs(removed), function_defs(added)
    moves = set()
    for old_path, names in removed_defs.items():
        for name in names - added_defs.get(old_path, set()):
            moves.update(
                (name, old_path, new_path)
                for new_path, new_names in added_defs.items()
                if new_path != old_path and name in new_names
            )
    return sorted(moves)
