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
WORD_OPERATORS = ("and", "or", "try", "catch")
# Longest first, so `//=` and `==` are not read as `=` or `/`.
SYMBOL_OPERATORS = ("//=", "|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=",
                    ">=", "//", "<", ">", "+", "-", "*", "/", "%", "=")
# A preceding character that makes the symbol a non-jq token (`:=`, `->`, `<<`).
SYMBOL_GUARDS = {"=": "=!<>|+-*/%:?^&~", "<": "<>-", ">": "<>-", "-": "<>-"}
CLOSERS = {")": "(", "]": "[", "}": "{"}
OPENERS = "([{"
SPACE = " \t\r\n"
TERM_CHAR = re.compile(r"[\w$.@?]")
WORD_CHAR = re.compile(r"[\w$.@]")
GLUED_KEYWORD = re.compile(r"(and|or|try|catch)(?=[(\[{\"$.])")
FIX_HINT = ("jq 1.7 and 1.8 group this binding differently; add parentheses that "
            "make the intended grouping explicit")


def _is_comment(line: str, index: int) -> bool:
    return line[index] == "#" and (index == 0 or line[index - 1] in " \t")


def _mask_line(line: str) -> str:
    """Blank a `#` comment that starts a word outside double quotes."""
    in_string = False
    index = 0
    while index < len(line):
        char = line[index]
        if in_string and char == "\\":
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif not in_string and _is_comment(line, index):
            return line[:index] + " " * (len(line) - index)
        index += 1
    return line


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


def _matching_open(text: str, index: int) -> int:
    """Return the opening bracket for the closing bracket at index, or -1."""
    expected: list[str] = []
    while index >= 0:
        char = text[index]
        if _is_quote(text, index):
            index = _string_start(text, index)
        elif char in CLOSERS:
            expected.append(CLOSERS[char])
        elif char in OPENERS:
            if expected.pop() != char:
                return -1
            if not expected:
                return index
        index -= 1
    return -1


def _term_start(text: str, end: int) -> int:
    """Return where the postfix term ending at index end starts, or -1."""
    start = -1
    index = end
    while index >= 0:
        char = text[index]
        if char in CLOSERS:
            opened = _matching_open(text, index)
        elif _is_quote(text, index):
            opened = _string_start(text, index)
        elif TERM_CHAR.match(char):
            opened = index
        else:
            break
        if opened < 0:
            return -1
        start = opened
        index = opened - 1
    return start


def _word_before(text: str, last: int) -> str | None:
    for operator in WORD_OPERATORS:
        first = last - len(operator) + 1
        if first >= 0 and text[first:last + 1] == operator and (
                first == 0 or not WORD_CHAR.match(text[first - 1])):
            return operator
    return None


def _symbol_before(text: str, last: int) -> str | None:
    for operator in SYMBOL_OPERATORS:
        first = last - len(operator) + 1
        if first < 0 or text[first:last + 1] != operator:
            continue
        if first > 0 and text[first - 1] in SYMBOL_GUARDS.get(operator, ""):
            return None
        return operator
    return None


def _operator_before(text: str, start: int) -> str | None:
    """Return the jq operator token that ends just before index start."""
    last = start - 1
    while last >= 0 and text[last] in SPACE:
        last -= 1
    if last < 0:
        return None
    operator = _word_before(text, last) or _symbol_before(text, last)
    # `%s as $X` is a printf conversion in shell text, not jq modulo.
    if operator == "%" and last == start - 1:
        return None
    return operator


def _binding_operator(masked: str, match: re.Match[str]) -> tuple[int, str] | None:
    """Return (term start, operator) when the binding's term follows an operator."""
    end = match.start() - 1
    while end >= 0 and masked[end] in SPACE:
        end -= 1
    start = _term_start(masked, end) if end >= 0 else -1
    if start < 0:
        return None
    glued = GLUED_KEYWORD.match(masked, start, end + 1)
    operator = glued.group(1) if glued else _operator_before(masked, start)
    return None if operator is None else (start, operator)


def scan_text(text: str) -> list[tuple[int, str, str]]:
    """Return (line, operator, snippet) for each ambiguous binding."""
    lines = text.split("\n")
    masked = "\n".join(_mask_line(line) for line in lines)
    line_starts = [0] + [newline.end() for newline in re.finditer("\n", masked)]
    findings = []
    for match in BINDING.finditer(masked):
        found = _binding_operator(masked, match)
        if found is None:
            continue
        start, operator = found
        line = bisect.bisect_right(line_starts, match.start())
        if line >= 2 and SUPPRESS.search(lines[line - 2]):
            continue
        snippet = " ".join(text[max(0, start - 30):match.end() + 12].split())
        findings.append((line, operator, snippet))
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
