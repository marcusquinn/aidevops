#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build markdoc-extract tag JSON from parser TSV.

This helper keeps the Python tag-shaping logic out of the shell wrapper so the
shell function-complexity scanner measures only shell orchestration.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ATTR_RE = re.compile(
    r"(?:^|\s)([\w-]+)\s*=\s*(?:\"([^\"]*)\"|\047([^\047]*)\047|([^\s\"\']+))"
)


def line_col_to_char(lines: list[str], line_num: int, col_num: int) -> int:
    """Convert 1-based line/col to a 0-based character offset."""
    offset = sum(len(lines[i]) + 1 for i in range(line_num - 1))
    return offset + (col_num - 1)


def parse_rows(tsv_data: str) -> list[dict[str, Any]]:
    """Parse tag parser TSV into row dictionaries."""
    rows: list[dict[str, Any]] = []
    for row in tsv_data.strip().split("\n"):
        if not row.strip():
            continue
        parts = row.split("\t", 5)
        if len(parts) < 6:
            parts += [""] * (6 - len(parts))
        ln, col, tag, is_close, is_self, attrs = parts
        rows.append(
            {
                "line": int(ln),
                "col": int(col),
                "tag": tag,
                "is_close": is_close == "1",
                "is_self": is_self == "1",
                "attrs_str": attrs,
            }
        )
    return rows


def parse_attrs(attrs_str: str) -> dict[str, str]:
    """Parse a Markdoc-style attrs string into a JSON-ready dict."""
    result: dict[str, str] = {}
    for match in ATTR_RE.finditer(attrs_str):
        key = match.group(1)
        val = (
            match.group(2)
            if match.group(2) is not None
            else match.group(3)
            if match.group(3) is not None
            else match.group(4)
        )
        result[key] = val
    return result


def tag_end(content: str, char_pos: int) -> int:
    """Return the end offset for the tag marker starting near char_pos."""
    marker_end = content.find("%}", char_pos)
    if marker_end != -1:
        return marker_end + 2
    return char_pos


def close_tag(
    results: list[dict[str, Any]], open_stack: list[dict[str, Any]], tag: str, line_num: int, close_end: int
) -> None:
    """Update the matching open tag result when a close tag is encountered."""
    matched_idx = None
    for idx in range(len(open_stack) - 1, -1, -1):
        if open_stack[idx]["tag"] == tag:
            matched_idx = idx
            break
    if matched_idx is None:
        return

    open_entry = open_stack.pop(matched_idx)
    result_idx = open_entry["result_idx"]
    results[result_idx]["char_end"] = close_end
    results[result_idx]["line_end"] = line_num


def append_self_closing_tag(
    results: list[dict[str, Any]], tag: str, attrs_str: str, char_pos: int, end_pos: int, line_num: int
) -> None:
    """Append an inline self-closing tag result."""
    results.append(
        {
            "tag": tag,
            "attrs": parse_attrs(attrs_str),
            "scope": "inline",
            "char_start": char_pos,
            "char_end": end_pos,
            "line_start": line_num,
            "line_end": line_num,
        }
    )


def append_open_tag(
    results: list[dict[str, Any]], open_stack: list[dict[str, Any]], tag: str, attrs_str: str, char_pos: int, end_pos: int, line_num: int
) -> None:
    """Append an opening tag result and push it on the open-tag stack."""
    scope = "section" if open_stack else "file"
    result_idx = len(results)
    results.append(
        {
            "tag": tag,
            "attrs": parse_attrs(attrs_str),
            "scope": scope,
            "char_start": char_pos,
            "char_end": end_pos,
            "line_start": line_num,
            "line_end": line_num,
        }
    )
    open_stack.append(
        {
            "tag": tag,
            "char_start": char_pos,
            "line_start": line_num,
            "result_idx": result_idx,
        }
    )


def build_tags(content: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Build the tag JSON array from parsed tag rows."""
    lines = content.split("\n")
    results: list[dict[str, Any]] = []
    open_stack: list[dict[str, Any]] = []

    for row in rows:
        tag = row["tag"]
        line_num = row["line"]
        char_pos = line_col_to_char(lines, line_num, row["col"])
        end_pos = tag_end(content, char_pos)

        if row["is_close"]:
            close_tag(results, open_stack, tag, line_num, end_pos)
        elif row["is_self"]:
            append_self_closing_tag(results, tag, row["attrs_str"], char_pos, end_pos, line_num)
        else:
            append_open_tag(results, open_stack, tag, row["attrs_str"], char_pos, end_pos, line_num)

    return results


def main(argv: list[str]) -> int:
    """CLI entry point."""
    if len(argv) != 3:
        print("usage: markdoc-tags-json.py <file> <tags.tsv>", file=sys.stderr)
        return 2

    file_path = Path(argv[1])
    tsv_path = Path(argv[2])
    content = file_path.read_text(encoding="utf-8")
    rows = parse_rows(tsv_path.read_text(encoding="utf-8"))
    print(json.dumps(build_tags(content, rows), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
