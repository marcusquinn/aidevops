#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression tests for report Markdown block rendering helpers."""

from __future__ import annotations

import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SCRIPTS_DIR = os.path.join(_REPO_ROOT, ".agents", "scripts")
sys.path.insert(0, _SCRIPTS_DIR)

from report_render_blocks import split_markdown_table_row  # noqa: E402


def assert_equal(actual: object, expected: object, description: str) -> None:
    if actual != expected:
        raise AssertionError(f"{description}: expected {expected!r}, got {actual!r}")


def test_split_markdown_table_row_unescapes_backslash_pairs() -> None:
    row = r"| before \\a | before \\| after | trailing \\ |"
    assert_equal(
        split_markdown_table_row(row),
        [r" before \a ", " before \\", r" after ", r" trailing \ "],
        "table rows unescape double backslashes before text, delimiters, and row end",
    )


def test_split_markdown_table_row_keeps_escaped_pipes_in_cell() -> None:
    row = r"| literal \| pipe | delimiter |"
    assert_equal(
        split_markdown_table_row(row),
        [" literal | pipe ", " delimiter "],
        "odd backslash before pipe keeps the pipe inside the current cell",
    )


def main() -> int:
    test_split_markdown_table_row_unescapes_backslash_pairs()
    test_split_markdown_table_row_keeps_escaped_pipes_in_cell()
    print("report_render_blocks tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
