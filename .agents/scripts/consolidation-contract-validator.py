#!/usr/bin/env python3
"""Validate successor dispatch contracts against every superseded issue body.

The successor must also carry the exact consolidated-spec marker line that the
pulse dispatch gate (GH#23187) requires; otherwise it is never dispatched.
Local text only: no API calls, credential reads, or secret values are needed.
Repeated requires-secrets lines are intentional: runner-capability-helper.sh
unions their comma/space-separated names before testing runner eligibility.
"""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

from __future__ import annotations

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


def prerequisite_errors(source: str, successor: str) -> list[str]:
    """Require exact source prerequisite lines and paragraphs."""
    errors = []
    successor_lines = set(successor.splitlines())
    successor_paragraphs = set(re.split(r"\n\s*\n", successor.strip()))
    for line in source.splitlines():
        if line.startswith("requires-secrets:") and line not in successor_lines:
            errors.append("missing verbatim requires-secrets line")
    for paragraph in re.split(r"\n\s*\n", source.strip()):
        is_prerequisite = (re.search(r"^requires-secrets:", paragraph, re.MULTILINE)
                           or re.search(r"runner[- ]prerequisite", paragraph, re.IGNORECASE))
        if is_prerequisite and paragraph not in successor_paragraphs:
            errors.append("missing verbatim runner-prerequisite paragraph")
    return errors


def scope_errors(source: str, successor: str) -> list[str]:
    """Reject generated-path narrowing and existing-path reclassification."""
    errors = []
    successor_scope = scope_entries(successor)
    scope_lines = {line for _, _, line in successor_scope}
    new_paths = {path for marker, path, _ in successor_scope if marker == "NEW"}
    for marker, path, line in scope_entries(source):
        if any(char in path for char in "*?[") and line not in scope_lines:
            errors.append("missing verbatim wildcard Files Scope entry")
        if marker == "EDIT" and path in new_paths:
            errors.append("EDIT scope entry changed to NEW")
    return errors


# Same exact-line contract as _has_consolidated_label (pulse-dispatch-commit-gates.sh)
# and the dispatch-dedup/reconcile marker parsers. Lines split on LF only: the jq
# dispatch gate does not strip CR, so a CRLF marker line would still be refused.
MARKER_RE = re.compile(r"_Supersedes #([0-9]+) (?:—|-) this issue is the consolidated spec\._")
MARKER_EXAMPLE = "_Supersedes #<N> — this issue is the consolidated spec._"


def marker_errors(successor: str, parents: list[int] | None = None) -> list[str]:
    """Require the exact consolidated-spec marker line the dispatch gate matches."""
    lines = successor.split("\n")
    refs = [int(match[1]) for line in lines if (match := MARKER_RE.fullmatch(line))]
    errors = []
    if not refs:
        near_miss = any(line.lstrip().startswith("_Supersedes #") for line in lines)
        detail = (" (a _Supersedes line exists but has extra text or trailing whitespace;"
                  " put other lineage on a separate line)" if near_miss else "")
        errors.append(f"successor: missing exact marker line `{MARKER_EXAMPLE}`{detail};"
                      " the dispatch gate refuses consolidated successors without it")
    for parent in parents or []:
        if refs and parent not in refs:
            errors.append(f"successor: missing exact marker line for parent #{parent}")
    if parents:
        for ref in dict.fromkeys(refs):
            if ref not in parents:
                errors.append(f"successor: marker references #{ref}, which is not a --parent")
    return errors


def validate(sources: list[str], successor: str, parents: list[int] | None = None) -> list[str]:
    """Fail closed when the marker or a preserved dispatch contract is missing or narrowed."""
    errors = marker_errors(successor, parents)
    # Contract text retains universal-newline semantics; only the marker is byte-exact.
    successor = successor.replace("\r\n", "\n").replace("\r", "\n")
    for index, source in enumerate(sources, start=1):
        source = source.replace("\r\n", "\n").replace("\r", "\n")
        findings = prerequisite_errors(source, successor) + scope_errors(source, successor)
        errors.extend(f"source {index}: {finding}" for finding in findings)
    return list(dict.fromkeys(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", required=True, type=Path,
                        help="verbatim superseded body file; repeat for every source")
    parser.add_argument("--successor", required=True, type=Path)
    parser.add_argument("--parent", action="append", type=int, default=[],
                        help="superseded issue number; repeat for every source issue."
                             " Each needs its own exact marker line")
    args = parser.parse_args()
    if len(args.parent) != len(args.source) or len(set(args.parent)) != len(args.parent):
        parser.error("--parent must contain one unique issue number for each --source")
    try:
        # Preserve CR for the exact marker check; validate normalizes contract text only.
        errors = validate([path.read_bytes().decode("utf-8") for path in args.source],
                          args.successor.read_bytes().decode("utf-8"), args.parent)
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
