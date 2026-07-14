#!/usr/bin/env python3
"""Read completed tool results from an OpenCode session database."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import tempfile
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


def extract_opencode_export(path: Path, session_id: str) -> tuple[list[ToolResult], int]:
    """Read the exact active session through OpenCode without a recent-session fallback."""
    if not session_id:
        raise ValueError("--session is required for an active OpenCode export")
    if not path.is_file():
        raise ValueError("OpenCode database is unavailable")

    temp_dir = Path(
        os.environ.get(
            "AIDEVOPS_TEMP_DIR",
            Path.home() / ".aidevops" / ".agent-workspace" / "tmp",
        )
    )
    if not temp_dir.is_dir():
        raise ValueError("active OpenCode transcript was unavailable")

    try:
        with tempfile.TemporaryFile(mode="w+b", dir=temp_dir) as export_file:
            completed = subprocess.run(
                ["opencode", "export", session_id, "--pure"],
                stdout=export_file,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=30,
            )
            if completed.returncode != 0:
                raise ValueError("active OpenCode transcript was unavailable")
            export_file.seek(0)
            document = json.load(export_file)
    except (FileNotFoundError, json.JSONDecodeError, OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("active OpenCode transcript was unavailable") from error

    if not isinstance(document, dict):
        raise ValueError("active OpenCode transcript was malformed")
    info = document.get("info")
    if not isinstance(info, dict) or info.get("id") != session_id:
        raise ValueError("active OpenCode transcript did not match the requested session")
    messages = document.get("messages")
    if not isinstance(messages, list):
        raise ValueError("active OpenCode transcript was malformed")

    results: list[ToolResult] = []
    parse_errors = 0
    for message in messages:
        if not isinstance(message, dict):
            parse_errors += 1
            continue
        parts = message.get("parts", [])
        if not isinstance(parts, list):
            parse_errors += 1
            continue
        for part in parts:
            if not isinstance(part, dict):
                parse_errors += 1
                continue
            result = result_from_opencode_part(part)
            if result is not None:
                results.append(result)
    return results, parse_errors
