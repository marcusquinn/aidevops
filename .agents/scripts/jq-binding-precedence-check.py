#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reject jq bindings that jq 1.7 and jq 1.8 group differently.

jq 1.8 changed binding precedence (jq 1.8 NEWS, a breaking change: jqlang/jq
#3053 and #3326). When the source term of ``TERM as $x | BODY`` follows an
operator, jq 1.7 binds only TERM and makes the whole binding the operator's
right operand; jq 1.8 binds the whole operator expression.
So ``true and "s" as $x | $x | type`` yields ``true`` on 1.7 and ``"boolean"``
on 1.8. This affects ``and``, ``or``, comparisons, arithmetic (including unary
minus), ``//``, every assignment operator, ``try`` and ``catch``. Comma, pipe,
semicolon, colon, brackets and keywords such as ``then``, ``reduce`` and
``def`` are unaffected.

CI and macOS ``/usr/bin/jq`` run jq 1.7 while Homebrew runners run jq 1.8, so an
ungrouped binding passes tests on one and silently misbehaves on the other
(GH#35920). Fix: start the binding at the beginning of a pipe or of a
parenthesized group that makes the intended grouping explicit.

jq programs live inside shell, Python and YAML strings, so this is a text scan,
not a jq parse. It ignores ``#`` comments and steps over string literals and
bracketed groups to find the term before ``as``. Scanned: ``.sh``, ``.bash``,
``.jq``, ``.py``, ``.yml`` and ``.yaml`` files plus extensionless scripts with
a shell or Python shebang; missing paths are skipped.

Override, only for text that is not a jq binding (prose, another language):
put ``# jq-binding-precedence: ignore next -- <reason>`` on the line before the
reported line. The reason is required; a bare marker does not suppress.

Usage: jq-binding-precedence-check.py FILE [FILE ...]
       jq-binding-precedence-check.py -    (newline-separated paths on stdin)
Exit: 0 clean, 1 ambiguous bindings found.
"""

from __future__ import annotations

import bisect
import re
import sys
from pathlib import Path

SUFFIXES = {".sh", ".bash", ".jq", ".py", ".yml", ".yaml"}
SHEBANG = re.compile(rb"#![^\n]*\b(?:bash|sh|zsh|ksh|dash|python3?)\b")
# The checker and its test quote the rejected shape on purpose.
SELF_EXEMPT = {"jq-binding-precedence-check.py", "test-jq-binding-precedence-check.sh"}
# The override must carry a reason after `ignore next`.
SUPPRESS = re.compile(r"#\s*jq-binding-precedence:\s*ignore next\b\s*\S")

# `as` followed by a binding pattern: $name (shell-escaped \$name), [ or {.
BINDING = re.compile(r"(?<![\w$.@])as\s*(?=\\?\$[A-Za-z_]|\[|\{)")
# A double-quoted string, which may run to the end of its line, or a `#` comment
# that starts a word. Comments are blanked; strings are kept, so a `#` inside a
# string is not read as a comment.
STRING_OR_COMMENT = re.compile(r'"(?:\\.|[^"\\\n])*(?:"|\\?$)|(?<![^ \t\n])#[^\n]*',
                               re.MULTILINE)
# A jq operator ending at the end of the searched window. The leftmost match is
# the longest, so `//=` and `==` are not read as `=` or `/`. A one-character
# symbol after a character that makes it a non-jq token (`:=`, `->`, `<<`) is
# not an operator.
OPERATOR_AT_END = re.compile(
    r"(?:(?<![\w$.@])(?:and|or|try|catch)"
    r"|//=|\|=|\+=|-=|\*=|/=|%=|==|!=|<=|>=|//|[+*/%]"
    r"|(?<![<>-])[<>-]|(?<![=!<>|+\-*/%:?^&~])=)\Z")
LONGEST_OPERATOR = len("catch")
CLOSERS = {")": "(", "]": "[", "}": "{"}
OPENERS = "([{"
SPACE = " \t\r\n"
TERM_CHAR = re.compile(r"[\w$.@?]")
GLUED_KEYWORD = re.compile(r"(and|or|try|catch)(?=[(\[{\"$.])")
FIX_HINT = ("jq 1.7 and 1.8 group this binding differently; add parentheses that "
            "make the intended grouping explicit")


def _blank_comment(match: re.Match[str]) -> str:
    piece = match.group()
    return piece if piece.startswith('"') else " " * len(piece)


def _escaped(text: str, index: int) -> bool:
    count = 0
    index -= 1
    while index >= 0 and text[index] == "\\":
        count += 1
        index -= 1
    return count % 2 == 1


def _is_quote(text: str, index: int) -> bool:
    return text[index] == '"' and not _escaped(text, index)


def _string_start(text: str, index: int) -> int:
    """Return the opening quote of the string closing at index, or -1."""
    index -= 1
    while index >= 0 and not _is_quote(text, index):
        index -= 1
    return index


def _piece_start(text: str, index: int) -> int:
    """Return where the bracket group, string or character ending at index
    starts, or -1 when the group or string never opens."""
    if text[index] in CLOSERS:
        return _matching_open(text, index)
    if _is_quote(text, index):
        return _string_start(text, index)
    return index


def _matching_open(text: str, index: int) -> int:
    """Return the opening bracket for the closing bracket at index, or -1."""
    opener = CLOSERS[text[index]]
    index -= 1
    while index >= 0 and text[index] not in OPENERS:
        index = _piece_start(text, index) - 1
    return index if index >= 0 and text[index] == opener else -1


def _ends_term_piece(text: str, index: int) -> bool:
    char = text[index]
    return char in CLOSERS or _is_quote(text, index) or TERM_CHAR.match(char) is not None


def _term_start(text: str, end: int) -> int:
    """Return where the postfix term ending at index end starts, or -1."""
    index = end
    while index >= 0 and _ends_term_piece(text, index):
        index = _piece_start(text, index) - 1
    # -2: a group or string never opened. end: no term before `as`.
    return -1 if index in (-2, end) else index + 1


def _last_non_space(text: str, index: int) -> int:
    """Return the last non-whitespace index at or before index, or -1."""
    while index >= 0 and text[index] in SPACE:
        index -= 1
    return index


def _operator_before(text: str, start: int) -> str | None:
    """Return the jq operator token that ends just before index start."""
    last = _last_non_space(text, start - 1)
    found = OPERATOR_AT_END.search(text, max(0, last + 1 - LONGEST_OPERATOR), last + 1)
    # `%s as $X` is a printf conversion in shell text, not jq modulo.
    if found is None or (found.group() == "%" and last == start - 1):
        return None
    return found.group()


def _binding_operator(masked: str, match: re.Match[str]) -> tuple[int, str] | None:
    """Return (term start, operator) when the binding's term follows an operator."""
    end = _last_non_space(masked, match.start() - 1)
    start = _term_start(masked, end)
    if start < 0:
        return None
    glued = GLUED_KEYWORD.match(masked, start, end + 1)
    operator = glued.group(1) if glued else _operator_before(masked, start)
    return None if operator is None else (start, operator)


def _suppressed(lines: list[str], line: int) -> bool:
    """Return whether the line before 1-based line carries the override."""
    return line >= 2 and SUPPRESS.search(lines[line - 2]) is not None


def scan_text(text: str) -> list[tuple[int, str, str]]:
    """Return (line, operator, snippet) for each ambiguous binding."""
    lines = text.split("\n")
    masked = STRING_OR_COMMENT.sub(_blank_comment, text)
    line_starts = [0] + [newline.end() for newline in re.finditer("\n", masked)]
    findings = []
    for match in BINDING.finditer(masked):
        found = _binding_operator(masked, match)
        line = bisect.bisect_right(line_starts, match.start())
        if found and not _suppressed(lines, line):
            snippet = " ".join(text[max(0, found[0] - 30):match.end() + 12].split())
            findings.append((line, found[1], snippet))
    return findings


def check_file(path: Path) -> list[str]:
    """Return violation messages for one file; unreadable files are skipped."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"{path}: skipped ({type(exc).__name__})", file=sys.stderr)
        return []
    return [f"{path}:{line}: binding after '{operator}': {FIX_HINT}: {snippet}"
            for line, operator, snippet in scan_text(text)]


def _selected(name: str) -> bool:
    """Select existing jq-bearing files: known suffixes or a script shebang."""
    path = Path(name)
    if path.name in SELF_EXEMPT or not path.is_file():
        return False
    if path.suffix:
        return path.suffix in SUFFIXES
    try:
        with path.open("rb") as handle:
            first_line = handle.readline(256)
    except OSError:
        return False
    return SHEBANG.match(first_line) is not None


def main(argv: list[str]) -> int:
    names = sys.stdin.read().splitlines() if argv == ["-"] else argv
    violations: list[str] = []
    for name in filter(_selected, names):
        violations.extend(check_file(Path(name)))
    for message in violations:
        print(message)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
