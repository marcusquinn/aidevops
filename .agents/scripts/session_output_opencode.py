#!/usr/bin/env python3
"""Read completed tool results from an OpenCode session database."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from session_output_transcript import ToolResult, result_from_opencode_part


def extract_opencode_db(path: Path, session_id: str) -> tuple[list[ToolResult], int]:
    if not session_id:
        raise ValueError("--session is required for an OpenCode database")
    if not path.is_file():
        raise ValueError("OpenCode database is unavailable")
    results: list[ToolResult] = []
    parse_errors = 0
    row_count = 0
    uri = f"{path.absolute().as_uri()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute(
            "SELECT data FROM part WHERE session_id = ? ORDER BY time_created, id",
            (session_id,),
        )
        for (raw_data,) in rows:
            row_count += 1
            try:
                part = json.loads(raw_data)
            except (TypeError, json.JSONDecodeError):
                parse_errors += 1
                continue
            if isinstance(part, dict):
                result = result_from_opencode_part(part)
                if result is not None:
                    results.append(result)
    if row_count == 0:
        raise ValueError("session transcript was not found")
    return results, parse_errors
