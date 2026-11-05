#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Classify or patch a Dependabot config so aidevops reusable workflows are ignored.

aidevops callers pin `uses: marcusquinn/aidevops/...@<sha> # vX.Y.Z` together with
a matching `with.aidevops_ref` input. Dependabot bumps only the `uses:` SHA, so
every framework release produces a stale PR that also breaks that pairing. Pins
advance through `aidevops sync-workflows --force-ref` instead (GH#36723).

The transform is line-based (stdlib only, no YAML library) so comments and
layout survive byte-for-byte. It only inserts lines into `github-actions`
update entries. Anything it cannot place with certainty is reported as
UNSUPPORTED rather than guessed.

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
EXIT_EXCLUDED = 3
EXIT_NO_ACTIONS = 4
EXIT_UNSUPPORTED = 5

_COMMENT = "# aidevops pins move with aidevops_ref via `aidevops sync-workflows`."
_ECOSYSTEM_RE = re.compile(r"""^package-ecosystem:\s*(["']?)github-actions\1\s*(#.*)?$""")
_ANY_ECOSYSTEM_RE = re.compile(r"^package-ecosystem:")
_UPDATES_RE = re.compile(r"^updates:\s*(#.*)?$")
_IGNORE_BLOCK_RE = re.compile(r"^ignore:\s*(#.*)?$")
_IGNORE_ANY_RE = re.compile(r"^ignore:")
_DEP_NAME_RE = re.compile(r"""^(?:-\s+)?dependency-name:\s*(?P<value>"[^"]*"|'[^']*'|[^\s#]+)\s*(#.*)?$""")
_RESTRICTION_RE = re.compile(r"^(?:-\s+)?(versions|update-types):")


class Unsupported(ValueError):
    """Raised when the layout cannot be patched without guessing."""


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_content(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("#")


def _is_dash(line: str, indent: int) -> bool:
    if _indent(line) != indent:
        return False
    rest = line[indent:]
    return rest == "-" or rest.startswith("- ")


def _updates_block(lines: list[str]) -> tuple[int, int]:
    starts = [i for i, line in enumerate(lines) if _UPDATES_RE.match(line)]
    if not starts:
        if any(line.startswith("updates:") for line in lines):
            raise Unsupported("flow-style-updates")
        raise Unsupported("no-updates-key")
    if len(starts) > 1:
        raise Unsupported("duplicate-updates-key")
    start = starts[0] + 1
    end = start
    while end < len(lines):
        line = lines[end]
        if _is_content(line) and _indent(line) == 0 and not line.startswith("-"):
            break
        end += 1
    return start, end


def _items(lines: list[str], start: int, end: int) -> list[tuple[int, int, int]]:
    """Return (item_start, item_end, key_indent) for each update entry."""
    first = next((i for i in range(start, end) if _is_content(lines[i])), None)
    if first is None:
        return []
    dash_indent = _indent(lines[first])
    if not _is_dash(lines[first], dash_indent):
        raise Unsupported("updates-not-block-sequence")
    starts: list[int] = []
    for i in range(first, end):
        line = lines[i]
        if not _is_content(line):
            continue
        if _indent(line) < dash_indent:
            raise Unsupported("ambiguous-updates-indent")
        if _is_dash(line, dash_indent):
            starts.append(i)
    items = []
    for n, item_start in enumerate(starts):
        item_end = starts[n + 1] if n + 1 < len(starts) else end
        match = re.match(r"^(\s*)-(\s+)(.*)$", lines[item_start])
        if match and match.group(3):
            if match.group(3).startswith("{"):
                raise Unsupported("flow-style-update-entry")
            key_indent = dash_indent + 1 + len(match.group(2))
        else:
            nxt = next((i for i in range(item_start + 1, item_end) if _is_content(lines[i])), None)
            if nxt is None:
                raise Unsupported("empty-update-entry")
            key_indent = _indent(lines[nxt])
        items.append((item_start, item_end, key_indent))
    return items


def _key_lines(lines: list[str], item: tuple[int, int, int]) -> list[tuple[int, str]]:
    item_start, item_end, key_indent = item
    first = lines[item_start]
    keys = [(item_start, first[key_indent:].strip())] if len(first.strip()) > 1 else []
    for i in range(item_start + 1, item_end):
        line = lines[i]
        if _is_content(line) and _indent(line) == key_indent:
            keys.append((i, line.strip()))
    return keys


def _entry_excludes(entry: list[str]) -> bool:
    name = None
    for line in entry:
        stripped = line.strip()
        if _RESTRICTION_RE.match(stripped):
            return False
        match = _DEP_NAME_RE.match(stripped)
        if match:
            name = match.group("value").strip("\"'")
    if not name:
        return False
    return all(fnmatch.fnmatchcase(sample, name) for sample in SAMPLE_DEPENDENCIES)


def _plan_item(lines: list[str], item: tuple[int, int, int]) -> tuple[int, list[str]] | None:
    """Return (insert_after_index, new_lines) for a missing exclusion, else None."""
    item_start, item_end, key_indent = item
    keys = _key_lines(lines, item)
    ignore_keys = [(i, text) for i, text in keys if _IGNORE_ANY_RE.match(text)]
    pad = " " * key_indent
    if not ignore_keys:
        last = max(i for i in range(item_start, item_end) if _is_content(lines[i]))
        return last, [
            f"{pad}{_COMMENT}",
            f"{pad}ignore:",
            f'{pad}  - dependency-name: "{EXCLUSION_PATTERN}"',
        ]
    if len(ignore_keys) > 1:
        raise Unsupported("duplicate-ignore-key")
    ignore_index, ignore_text = ignore_keys[0]
    if not _IGNORE_BLOCK_RE.match(ignore_text):
        raise Unsupported("flow-style-ignore")
    region_start = ignore_index + 1
    first = next((i for i in range(region_start, item_end) if _is_content(lines[i])), None)
    if first is None or _indent(lines[first]) < key_indent or (
        _indent(lines[first]) == key_indent and not _is_dash(lines[first], key_indent)
    ):
        return ignore_index, [f'{pad}  - dependency-name: "{EXCLUSION_PATTERN}"']
    entry_indent = _indent(lines[first])
    if not _is_dash(lines[first], entry_indent):
        raise Unsupported("ignore-not-block-sequence")
    region_end = first
    while region_end < item_end:
        line = lines[region_end]
        if _is_content(line) and (
            _indent(line) < entry_indent
            or (_indent(line) == entry_indent and not _is_dash(line, entry_indent))
        ):
            break
        region_end += 1
    entries: list[list[str]] = []
    for i in range(first, region_end):
        line = lines[i]
        if not _is_content(line):
            continue
        if _is_dash(line, entry_indent):
            entries.append([line])
        elif entries:
            entries[-1].append(line)
    if any(_entry_excludes(entry) for entry in entries):
        return None
    last = max(i for i in range(first, region_end) if _is_content(lines[i]))
    entry_pad = " " * entry_indent
    return last, [f'{entry_pad}- dependency-name: "{EXCLUSION_PATTERN}"']


def plan(text: str) -> list[tuple[int, list[str]]]:
    """Return insertion plans; raise Unsupported; empty list means excluded."""
    if "\t" in text:
        raise Unsupported("tab-indentation")
    lines = text.splitlines()
    start, end = _updates_block(lines)
    actions = []
    for item in _items(lines, start, end):
        keys = _key_lines(lines, item)
        if not any(_ANY_ECOSYSTEM_RE.match(t) for _, t in keys):
            raise Unsupported("update-entry-without-ecosystem")
        if any(_ECOSYSTEM_RE.match(t) for _, t in keys):
            actions.append(item)
    if not actions:
        raise LookupError("no-actions")
    plans = []
    for item in actions:
        item_plan = _plan_item(lines, item)
        if item_plan is not None:
            plans.append(item_plan)
    return plans


def patch(text: str) -> str:
    newline = "\r\n" if "\r\n" in text else "\n"
    trailing = text.endswith(("\n", "\r"))
    lines = text.splitlines()
    for index, new_lines in sorted(plan(text), key=lambda p: p[0], reverse=True):
        lines[index + 1:index + 1] = new_lines
    patched = newline.join(lines) + (newline if trailing else "")
    if plan(patched):
        raise Unsupported("patch-did-not-converge")
    return patched


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in {"classify", "patch"}:
        print("usage: dependabot-aidevops-exclusion.py {classify|patch} < dependabot.yml", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8")
    mode = argv[1]
    try:
        missing = bool(plan(text))
    except LookupError:
        if mode == "classify":
            print("NO-ACTIONS")
            return 0
        print("no github-actions update entry", file=sys.stderr)
        return EXIT_NO_ACTIONS
    except Unsupported as exc:
        if mode == "classify":
            print(f"UNSUPPORTED:{exc}")
            return 0
        print(f"unsupported: {exc}", file=sys.stderr)
        return EXIT_UNSUPPORTED
    if mode == "classify":
        print("MISSING" if missing else "EXCLUDED")
        return 0
    if not missing:
        sys.stdout.write(text)
        return EXIT_EXCLUDED
    try:
        sys.stdout.write(patch(text))
    except Unsupported as exc:
        print(f"unsupported: {exc}", file=sys.stderr)
        return EXIT_UNSUPPORTED
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
