#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify or patch a Dependabot config so aidevops reusable workflows are ignored.

aidevops callers pin `uses: marcusquinn/aidevops/...@<sha> # vX.Y.Z` together with
a matching `with.aidevops_ref` input. Dependabot bumps only the `uses:` SHA, so
every framework release produces a stale PR that also breaks that pairing. Pins
advance through `aidevops sync-workflows --force-ref` instead (GH#36723).

The transform is line-based (stdlib only, no YAML library) so comments and
layout survive byte-for-byte. It only inserts lines into block-style
`github-actions` update entries. Anything it cannot place with certainty is
reported as UNSUPPORTED rather than guessed.

Usage: dependabot-aidevops-exclusion.py {classify|patch} < dependabot.yml

classify prints one of EXCLUDED, MISSING, NO-ACTIONS, UNSUPPORTED:<reason>.
patch prints the patched config. Exit codes: 0 changed (patch) or classified
(classify); 3 already excluded; 4 no github-actions entry; 5 unsupported.
"""

from __future__ import annotations

import fnmatch
import re
import sys

EXCLUSION_PATTERN = "marcusquinn/aidevops*"
# Dependabot names reusable-workflow dependencies by repository plus path.
SAMPLE_DEPENDENCIES = (
    "marcusquinn/aidevops",
    "marcusquinn/aidevops/.github/workflows/loc-badge-reusable.yml",
)
EXIT_CODES = {"EXCLUDED": 3, "NO-ACTIONS": 4}
EXIT_UNSUPPORTED = 5

_ENTRY = f'- dependency-name: "{EXCLUSION_PATTERN}"'
_COMMENT = "# aidevops pins move with aidevops_ref via `aidevops sync-workflows`."
_ECOSYSTEM_RE = re.compile(r"""^package-ecosystem:\s*(["']?)github-actions\1\s*(#.*)?$""")
_UPDATES_RE = re.compile(r"^updates:\s*(#.*)?$")
_IGNORE_BLOCK_RE = re.compile(r"^ignore:\s*(#.*)?$")
_ITEM_RE = re.compile(r"^(\s*-\s+)(\S.*)$")
_DEP_NAME_RE = re.compile(r"""^(?:-\s+)?dependency-name:\s*(?P<value>"[^"]*"|'[^']*'|[^\s#]+)\s*(#.*)?$""")
_RESTRICTION_RE = re.compile(r"^(?:-\s+)?(versions|update-types):")


class Unsupported(ValueError):
    """Raised when the layout cannot be patched without guessing."""


class NoActions(Exception):
    """Raised when no github-actions update entry exists."""


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_content(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("#")


def _is_dash(line: str) -> bool:
    stripped = line.lstrip(" ")
    return stripped == "-" or stripped.startswith("- ")


def _next_content(lines: list[str], start: int, end: int) -> int | None:
    return next((i for i in range(start, end) if _is_content(lines[i])), None)


def _last_content(lines: list[str], start: int, end: int) -> int:
    return max(i for i in range(start, end) if _is_content(lines[i]))


def _seq_end(lines: list[str], start: int, indent: int, end: int) -> int:
    """Index after a block sequence whose dashes sit at `indent`."""
    for i in range(start, end):
        line = lines[i]
        if not _is_content(line):
            continue
        if _indent(line) < indent or (_indent(line) == indent and not _is_dash(line)):
            return i
    return end


def _key_indent(line: str) -> int:
    match = _ITEM_RE.match(line)
    if not match or match.group(2).startswith("{"):
        raise Unsupported("update-entry-not-block-mapping")
    return len(match.group(1))


def _items(lines: list[str]) -> list[tuple[int, int, int]]:
    """Return (start, end, key_indent) for each `updates:` entry."""
    starts = [i for i, line in enumerate(lines) if _UPDATES_RE.match(line)]
    if len(starts) != 1:
        raise Unsupported("updates-not-single-block-key")
    first = _next_content(lines, starts[0] + 1, len(lines))
    if first is None or not _is_dash(lines[first]):
        raise Unsupported("updates-not-block-sequence")
    dash_indent = _indent(lines[first])
    end = _seq_end(lines, first, dash_indent, len(lines))
    heads = [i for i in range(first, end) if _is_content(lines[i]) and _indent(lines[i]) == dash_indent]
    bounds = zip(heads, heads[1:] + [end])
    return [(start, stop, _key_indent(lines[start])) for start, stop in bounds]


def _key_lines(lines: list[str], item: tuple[int, int, int]) -> list[tuple[int, str]]:
    start, end, key_indent = item
    keys = [(start, lines[start][key_indent:].strip())]
    keys += [
        (i, lines[i].strip())
        for i in range(start + 1, end)
        if _is_content(lines[i]) and _indent(lines[i]) == key_indent and not _is_dash(lines[i])
    ]
    return keys


def _entry_excludes(entry: list[str]) -> bool:
    if any(_RESTRICTION_RE.match(line) for line in entry):
        return False
    names = [m.group("value").strip("\"'") for m in map(_DEP_NAME_RE.match, entry) if m]
    return bool(names) and all(fnmatch.fnmatchcase(sample, names[0]) for sample in SAMPLE_DEPENDENCIES)


def _region_excludes(lines: list[str], first: int, end: int, entry_indent: int) -> bool:
    entries: list[list[str]] = []
    for i in range(first, end):
        if not _is_content(lines[i]):
            continue
        if _indent(lines[i]) == entry_indent:
            entries.append([])
        entries[-1].append(lines[i].strip())
    return any(_entry_excludes(entry) for entry in entries)


def _ignore_list_start(lines: list[str], ignores: list[tuple[int, str]], end: int, key_indent: int) -> int:
    """Return the first entry line of a single block-style `ignore:` list."""
    if len(ignores) > 1 or not _IGNORE_BLOCK_RE.match(ignores[0][1]):
        raise Unsupported("ignore-not-block-list")
    first = _next_content(lines, ignores[0][0] + 1, end)
    if first is None or _indent(lines[first]) < key_indent or not _is_dash(lines[first]):
        raise Unsupported("ignore-not-block-list")
    return first


def _plan_item(lines: list[str], item: tuple[int, int, int]) -> tuple[int, list[str]] | None:
    """Return (insert_after_index, new_lines) when the exclusion is missing."""
    start, end, key_indent = item
    pad = " " * key_indent
    ignores = [(i, text) for i, text in _key_lines(lines, item) if text.startswith("ignore:")]
    if not ignores:
        return _last_content(lines, start, end), [f"{pad}{_COMMENT}", f"{pad}ignore:", f"{pad}  {_ENTRY}"]
    first = _ignore_list_start(lines, ignores, end, key_indent)
    entry_indent = _indent(lines[first])
    region_end = _seq_end(lines, first, entry_indent, end)
    if _region_excludes(lines, first, region_end, entry_indent):
        return None
    return _last_content(lines, first, region_end), [" " * entry_indent + _ENTRY]


def plan(text: str) -> list[tuple[int, list[str]]]:
    """Return insertion plans; empty means excluded. Raises Unsupported/NoActions."""
    if "\t" in text:
        raise Unsupported("tab-indentation")
    lines = text.splitlines()
    actions = [
        item for item in _items(lines)
        if any(_ECOSYSTEM_RE.match(key) for _, key in _key_lines(lines, item))
    ]
    if not actions:
        raise NoActions("no-actions")
    return [p for p in (_plan_item(lines, item) for item in actions) if p is not None]


def classify(text: str) -> str:
    try:
        return "MISSING" if plan(text) else "EXCLUDED"
    except NoActions:
        return "NO-ACTIONS"
    except Unsupported as exc:
        return f"UNSUPPORTED:{exc}"


def patch(text: str) -> str:
    newline = "\r\n" if "\r\n" in text else "\n"
    trailing = text.endswith(("\n", "\r"))
    lines = text.splitlines()
    for index, new_lines in sorted(plan(text), key=lambda p: p[0], reverse=True):
        lines[index + 1:index + 1] = new_lines
    patched = newline.join(lines) + (newline if trailing else "")
    if classify(patched) != "EXCLUDED":
        raise Unsupported("patch-did-not-converge")
    return patched


def _write_patch(text: str) -> int:
    try:
        sys.stdout.write(patch(text))
    except Unsupported as exc:
        print(f"UNSUPPORTED:{exc}", file=sys.stderr)
        return EXIT_UNSUPPORTED
    return 0


def _run_patch(text: str, status: str) -> int:
    if status == "MISSING":
        return _write_patch(text)
    if status == "EXCLUDED":
        sys.stdout.write(text)
    else:
        print(status, file=sys.stderr)
    return EXIT_CODES.get(status, EXIT_UNSUPPORTED)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in {"classify", "patch"}:
        print("usage: dependabot-aidevops-exclusion.py {classify|patch} < dependabot.yml", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8")
    status = classify(text)
    if argv[1] == "classify":
        print(status)
        return 0
    return _run_patch(text, status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
