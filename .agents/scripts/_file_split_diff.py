# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Unified-diff parsing for file-split-verify.py."""

import collections
import re

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
BINARY_RE = re.compile(r"^(?:Binary files .* differ|GIT binary patch)$")


def diff_path(header_line, prefix):
    """Return the path from a `--- a/x` or `+++ b/x` header, or None."""
    value = header_line[4:].rstrip("\t")
    if value == "/dev/null":
        return None
    return value[len(prefix):] if value.startswith(prefix) else value


def binary_changes(text):
    """Return diff lines reporting binary changes the line parser cannot verify."""
    return [line for line in text.split("\n") if BINARY_RE.match(line)]


def mode_changes(text):
    """Return diff headers for mode changes on existing files (e.g. lost +x)."""
    changes, current = [], None
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            current = line[len("diff --git "):]
        elif line.startswith("old mode "):
            changes.append(f"{current}: {line}")
        elif line.startswith("new mode ") and changes:
            changes[-1] += f"; {line}"
    return changes


class _DiffParser:
    """Line-by-line state machine collecting removed and added entries."""

    def __init__(self):
        self.removed, self.added = [], []
        self.old_path = self.new_path = None
        self.old_no = self.new_no = 0
        self.in_hunk = False

    def feed(self, line):
        """Consume one diff line."""
        if line.startswith("diff --git "):
            self.old_path = self.new_path = None
            self.in_hunk = False
        elif not self.in_hunk and self._header(line):
            return
        elif HUNK_RE.match(line):
            self._start_hunk(HUNK_RE.match(line))
        elif self.in_hunk:
            self._body(line)

    def _header(self, line):
        if line.startswith("--- "):
            self.old_path = diff_path(line, "a/")
            return True
        if line.startswith("+++ "):
            self.new_path = diff_path(line, "b/")
            return True
        return False

    def _start_hunk(self, match):
        self.in_hunk = True
        self.old_no, self.new_no = int(match.group(1)), int(match.group(2))

    def _body(self, line):
        if line.startswith("-"):
            self.removed.append((self.old_path, self.old_no, line[1:].rstrip()))
            self.old_no += 1
        elif line.startswith("+"):
            self.added.append((self.new_path, self.new_no, line[1:].rstrip()))
            self.new_no += 1


def parse_diff(text):
    """Return (removed, added) lists of (path, line_no, content)."""
    parser = _DiffParser()
    for line in text.split("\n"):
        parser.feed(line)
    return parser.removed, parser.added


def unmatched(entries, surplus):
    """Return entries whose content is in the surplus multiset, in order."""
    remaining = collections.Counter(surplus)
    result = []
    for entry in entries:
        if remaining[entry[2]] > 0:
            remaining[entry[2]] -= 1
            result.append(entry)
    return result
