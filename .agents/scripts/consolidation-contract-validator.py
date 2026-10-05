#!/usr/bin/env python3
"""Validate successor dispatch contracts against every superseded issue body.

Local text only: no API calls, credential reads, or secret values are needed.
Repeated requires-secrets lines are intentional: runner-capability-helper.sh
unions their comma/space-separated names before testing runner eligibility.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import argparse
import re
import sys
from pathlib import Path


def scope_entries(body: str) -> list[tuple[str, str, str]]:
    """Return (marker, path, original line) from canonical scope sections."""
    entries = []
    in_scope = False
    for line in body.splitlines():
        if re.match(r"^#{1,6}\s", line):
            in_scope = line.strip() == "### Files Scope"
            continue
        if not in_scope:
            continue
        match = re.fullmatch(r"\s*-\s+`?(?:(EDIT|NEW):\s*)?([^`]+?)`?\s*", line)
        if match:
            entries.append((match[1] or "", match[2], line))
    return entries


def validate(sources: list[str], successor: str) -> list[str]:
    """Fail closed when a preserved dispatch contract is missing or narrowed."""
    errors = []
    successor_lines = set(successor.splitlines())
    successor_paragraphs = set(re.split(r"\n\s*\n", successor.strip()))
    successor_scope = scope_entries(successor)
    scope_lines = {line for _, _, line in successor_scope}
    new_paths = {path for marker, path, _ in successor_scope if marker == "NEW"}
    for index, source in enumerate(sources, start=1):
        prefix = f"source {index}"
        for line in source.splitlines():
            if line.startswith("requires-secrets:") and line not in successor_lines:
                errors.append(f"{prefix}: missing verbatim requires-secrets line")
        for paragraph in re.split(r"\n\s*\n", source.strip()):
            if (re.search(r"^requires-secrets:", paragraph, re.MULTILINE)
                    or re.search(r"runner[- ]prerequisite", paragraph, re.IGNORECASE)):
                if paragraph not in successor_paragraphs:
                    errors.append(f"{prefix}: missing verbatim runner-prerequisite paragraph")
        for marker, path, line in scope_entries(source):
            if any(char in path for char in "*?[") and line not in scope_lines:
                errors.append(f"{prefix}: missing verbatim wildcard Files Scope entry")
            if marker == "EDIT" and path in new_paths:
                errors.append(f"{prefix}: EDIT scope entry changed to NEW")
    return list(dict.fromkeys(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", required=True, type=Path,
                        help="verbatim superseded body file; repeat for every source")
    parser.add_argument("--successor", required=True, type=Path)
    args = parser.parse_args()
    try:
        errors = validate([path.read_text(encoding="utf-8") for path in args.source],
                          args.successor.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        # Avoid printing body contents, credential names, or private file paths.
        print(f"consolidation contract: cannot read body files ({type(exc).__name__})",
              file=sys.stderr)
        return 1
    for error in errors:
        print(f"consolidation contract: {error}", file=sys.stderr)
    if errors:
        return 1
    print("consolidation contract: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
