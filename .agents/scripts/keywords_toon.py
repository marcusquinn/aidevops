#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Minimal TOON reader/writer for the keyword registry.

Supports the subset the registry uses: root ``key: value`` scalars and root
pipe-delimited tabular arrays (``name[N|]{a|b}:`` followed by two-space
indented rows). Output decodes with the official ``@toon-format/cli``.
Values are kept as strings internally; empty cells mean "unknown".
"""

from __future__ import annotations

import re
from pathlib import Path

DELIM = "|"
HEADER_RE = re.compile(r"^([A-Za-z_][\w.-]*)\[(\d+)([|\t,]?)\]\{(.*)\}:\s*$")
SCALAR_RE = re.compile(r"^([A-Za-z_][\w.-]*):\s*(.*)$")
NUMBER_RE = re.compile(r"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$")
UNSAFE_RE = re.compile(r'[:"\\\[\]{}#|\t\n\r]')
LITERALS = {"true", "false", "null"}
ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}


class ToonError(ValueError):
    """Raised when a registry file is not decodable TOON."""


def _unquote(token: str) -> str:
    body = token[1:-1]
    out: list[str] = []
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\" and index + 1 < len(body):
            out.append(ESCAPES.get(body[index + 1], body[index + 1]))
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def decode_token(token: str) -> str:
    """Decode one scalar token to its string form ('' for empty/null)."""
    token = token.strip()
    if len(token) >= 2 and token.startswith('"') and token.endswith('"'):
        return _unquote(token)
    return "" if token == "null" else token


def _cell_pattern(delim: str) -> re.Pattern:
    sep = re.escape(delim)
    return re.compile(rf'[ ]*("(?:[^"\\]|\\.)*"|[^"{sep}]*?)[ ]*({sep}|$)')


def split_row(line: str, delim: str = DELIM) -> list[str]:
    """Split a row on the delimiter, respecting double-quoted cells."""
    pattern = _cell_pattern(delim)
    cells: list[str] = []
    position = 0
    while True:
        match = pattern.match(line, position)
        if match is None:
            raise ToonError(f"malformed row: {line.strip()}")
        cells.append(decode_token(match.group(1)))
        if not match.group(2):
            return cells
        position = match.end()


def _needs_quotes(text: str) -> bool:
    edges = text != text.strip() or text.startswith("-")
    return edges or text in LITERALS or bool(NUMBER_RE.match(text)) or bool(UNSAFE_RE.search(text))


def encode_value(value: object, numeric: bool = False) -> str:
    """Encode a cell value, quoting only when TOON requires it."""
    text = "" if value is None else str(value)
    if not text or (numeric and NUMBER_RE.match(text)) or not _needs_quotes(text):
        return text
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return f'"{escaped}"'


def _read_table(lines: list[str], start: int, match: re.Match) -> tuple[dict, int]:
    name, count, delim, fields_text = match.groups()
    delim = delim or ","
    fields = [decode_token(field) for field in fields_text.split(delim)] if fields_text else []
    rows: list[dict[str, str]] = []
    index = start + 1
    while index < len(lines) and lines[index].startswith("  "):
        cells = split_row(lines[index][2:], delim)
        if len(cells) != len(fields):
            raise ToonError(f"{name}: row {len(rows) + 1} has {len(cells)} cells, expected {len(fields)}")
        rows.append(dict(zip(fields, cells)))
        index += 1
    if len(rows) != int(count):
        raise ToonError(f"{name}: header declares {count} rows but found {len(rows)}")
    return {"name": name, "fields": fields, "rows": rows}, index


def parse(text: str) -> dict:
    """Parse registry TOON into scalars and tables."""
    scalars: dict[str, str] = {}
    tables: dict[str, dict] = {}
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        header = HEADER_RE.match(line)
        if header:
            table, index = _read_table(lines, index, header)
            tables[table["name"]] = table
            continue
        scalar = SCALAR_RE.match(line)
        if scalar:
            scalars[scalar.group(1)] = decode_token(scalar.group(2))
        elif line.strip():
            raise ToonError(f"unsupported TOON line {index + 1}: {line.strip()}")
        index += 1
    return {"scalars": scalars, "tables": tables}


def dumps(scalars: dict[str, str], tables: list[tuple[str, list[str], list[dict]]], numeric: set[str] | None = None) -> str:
    """Serialise scalars and pipe-delimited tables."""
    numeric = numeric or set()
    out = [f"{key}: {encode_value(value)}" for key, value in scalars.items()]
    for name, fields, rows in tables:
        out.append(f"{name}[{len(rows)}{DELIM}]{{{DELIM.join(fields)}}}:")
        for row in rows:
            cells = [encode_value(row.get(field, ""), field in numeric) for field in fields]
            out.append("  " + DELIM.join(cells))
    return "\n".join(out) + "\n"


def load(path: Path) -> dict:
    return parse(Path(path).read_text(encoding="utf-8"))


def dump(path: Path, scalars: dict[str, str], tables: list[tuple[str, list[str], list[dict]]], numeric: set[str] | None = None) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(scalars, tables, numeric), encoding="utf-8")
