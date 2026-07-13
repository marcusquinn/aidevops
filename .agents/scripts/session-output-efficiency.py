#!/usr/bin/env python3
"""Detect deterministic tool-output waste without reproducing transcript content."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sqlite3
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SCHEMA = "aidevops.session-output-efficiency/v1"


@dataclass(frozen=True)
class ToolResult:
    tool: str
    input_value: str
    output: str


def canonical(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def safe_tool_name(value: Any) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value or "unknown")).strip("-")
    return sanitized[:48] or "unknown"


def result_from_opencode_part(part: dict[str, Any]) -> ToolResult | None:
    if part.get("type") != "tool":
        return None
    state = part.get("state")
    if not isinstance(state, dict) or state.get("status") != "completed":
        return None
    return ToolResult(
        tool=safe_tool_name(part.get("tool")),
        input_value=canonical(state.get("input", {})),
        output=canonical(state.get("output", "")),
    )


def extract_jsonl(path: Path) -> tuple[list[ToolResult], int]:
    results: list[ToolResult] = []
    parse_errors = 0
    tool_uses: dict[str, tuple[str, str]] = {}

    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                parse_errors += 1
                continue
            if not isinstance(record, dict):
                continue

            data = record.get("data")
            if isinstance(data, str):
                try:
                    data = json.loads(data)
                except json.JSONDecodeError:
                    data = None
            if isinstance(data, dict):
                result = result_from_opencode_part(data)
                if result is not None:
                    results.append(result)
                    continue

            result = result_from_opencode_part(record)
            if result is not None:
                results.append(result)
                continue

            if "tool" in record and "output" in record:
                results.append(
                    ToolResult(
                        tool=safe_tool_name(record.get("tool")),
                        input_value=canonical(record.get("input", {})),
                        output=canonical(record.get("output", "")),
                    )
                )
                continue

            message = record.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue

            for item in content:
                if not isinstance(item, dict):
                    continue
                item_type = item.get("type")
                if item_type == "tool_use":
                    call_id = str(item.get("id") or "")
                    if call_id:
                        tool_uses[call_id] = (
                            safe_tool_name(item.get("name")),
                            canonical(item.get("input", {})),
                        )
                elif item_type == "tool_result":
                    call_id = str(item.get("tool_use_id") or "")
                    tool, input_value = tool_uses.get(call_id, ("unknown", "{}"))
                    results.append(
                        ToolResult(
                            tool=tool,
                            input_value=input_value,
                            output=canonical(item.get("content", "")),
                        )
                    )

    return results, parse_errors


def resolve_jsonl(source: Path, session_id: str) -> Path:
    if source.is_file():
        return source
    if not source.is_dir():
        raise ValueError("transcript source is unavailable")
    if not session_id:
        raise ValueError("--session is required when the transcript source is a directory")

    exact = source / f"{session_id}.jsonl"
    if exact.is_file():
        return exact
    matches = sorted(source.rglob(f"{session_id}.jsonl"))
    if not matches:
        matches = sorted(source.rglob(f"*{session_id}*.jsonl"))
    if not matches:
        raise ValueError("session transcript was not found")
    return matches[0]


def extract_opencode_db(path: Path, session_id: str) -> tuple[list[ToolResult], int]:
    if not session_id:
        raise ValueError("--session is required for an OpenCode database")
    if not path.is_file():
        raise ValueError("OpenCode database is unavailable")

    results: list[ToolResult] = []
    parse_errors = 0
    uri = f"file:{path}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute(
            "SELECT data FROM part WHERE session_id = ? ORDER BY time_created, id",
            (session_id,),
        )
        for (raw_data,) in rows:
            try:
                part = json.loads(raw_data)
            except (TypeError, json.JSONDecodeError):
                parse_errors += 1
                continue
            if not isinstance(part, dict):
                continue
            result = result_from_opencode_part(part)
            if result is not None:
                results.append(result)
    return results, parse_errors


def digest(*values: str) -> str:
    payload = "\0".join(values).encode("utf-8", errors="replace")
    return hashlib.sha256(payload).hexdigest()[:12]


def byte_length(value: str) -> int:
    return len(value.encode("utf-8", errors="replace"))


def analyse(
    results: Iterable[ToolResult],
    runtime: str,
    session_id: str,
    source_kind: str,
    parse_errors: int,
    min_repeat_bytes: int,
    oversized_bytes: int,
    max_findings: int,
) -> dict[str, Any]:
    materialized = list(results)
    total_bytes = sum(byte_length(result.output) for result in materialized)
    repeat_groups: dict[tuple[str, str, str], list[ToolResult]] = defaultdict(list)
    for result in materialized:
        size = byte_length(result.output)
        if size >= min_repeat_bytes:
            repeat_groups[
                (
                    result.tool,
                    digest(result.input_value),
                    digest(result.output),
                )
            ].append(result)

    repeat_findings: list[dict[str, Any]] = []
    redundant_results = 0
    redundant_bytes = 0
    for (tool, input_hash, output_hash), group in repeat_groups.items():
        if len(group) < 2:
            continue
        size = byte_length(group[0].output)
        redundant = len(group) - 1
        wasted = redundant * size
        redundant_results += redundant
        redundant_bytes += wasted
        repeat_findings.append(
            {
                "kind": "exact-repeat",
                "tool": tool,
                "fingerprint": digest(tool, input_hash, output_hash),
                "occurrences": len(group),
                "redundant_results": redundant,
                "bytes_each": size,
                "redundant_bytes": wasted,
                "approx_redundant_tokens": math.ceil(wasted / 4),
            }
        )

    oversized_groups: dict[tuple[str, str], list[ToolResult]] = defaultdict(list)
    for result in materialized:
        if byte_length(result.output) >= oversized_bytes:
            oversized_groups[(result.tool, digest(result.output))].append(result)

    oversized_findings: list[dict[str, Any]] = []
    for (tool, output_hash), group in oversized_groups.items():
        sizes = [byte_length(item.output) for item in group]
        oversized_findings.append(
            {
                "kind": "oversized-output",
                "tool": tool,
                "fingerprint": digest(tool, output_hash),
                "occurrences": len(group),
                "largest_bytes": max(sizes),
                "total_bytes": sum(sizes),
                "approx_total_tokens": math.ceil(sum(sizes) / 4),
            }
        )

    repeat_findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    oversized_findings.sort(key=lambda item: (-item["total_bytes"], item["tool"]))
    combined = repeat_findings + oversized_findings

    return {
        "schema": SCHEMA,
        "runtime": runtime,
        "session": session_id or None,
        "source": source_kind,
        "thresholds": {
            "minimum_repeat_bytes": min_repeat_bytes,
            "oversized_output_bytes": oversized_bytes,
        },
        "stats": {
            "completed_tool_results": len(materialized),
            "tool_output_bytes": total_bytes,
            "approx_tool_output_tokens": math.ceil(total_bytes / 4),
            "repeated_snapshot_groups": len(repeat_findings),
            "redundant_tool_results": redundant_results,
            "redundant_output_bytes": redundant_bytes,
            "approx_redundant_tokens": math.ceil(redundant_bytes / 4),
            "oversized_tool_results": sum(len(group) for group in oversized_groups.values()),
            "parse_errors": parse_errors,
        },
        "findings": combined[:max_findings],
        "privacy": "Raw tool inputs, outputs, commands, and paths are omitted.",
    }


def print_text(report: dict[str, Any]) -> None:
    stats = report["stats"]
    thresholds = report["thresholds"]
    print("## Output Efficiency")
    print(
        "Completed tool results: "
        f"{stats['completed_tool_results']} "
        f"({stats['tool_output_bytes']} bytes; ~{stats['approx_tool_output_tokens']} tokens)"
    )
    print(
        "Repeated unchanged snapshots: "
        f"{stats['repeated_snapshot_groups']} groups, "
        f"{stats['redundant_tool_results']} redundant results, "
        f"{stats['redundant_output_bytes']} redundant bytes"
    )
    print(
        "Oversized tool results: "
        f"{stats['oversized_tool_results']} "
        f"(threshold {thresholds['oversized_output_bytes']} bytes)"
    )
    if stats["parse_errors"]:
        print(f"Unparsed transcript records: {stats['parse_errors']}")
    print("Candidates:")
    if not report["findings"]:
        print("- None above deterministic thresholds")
    for finding in report["findings"]:
        if finding["kind"] == "exact-repeat":
            print(
                f"- exact-repeat {finding['fingerprint']}: tool={finding['tool']}, "
                f"occurrences={finding['occurrences']}, "
                f"redundant_bytes={finding['redundant_bytes']}"
            )
        else:
            print(
                f"- oversized-output {finding['fingerprint']}: tool={finding['tool']}, "
                f"occurrences={finding['occurrences']}, "
                f"largest_bytes={finding['largest_bytes']}"
            )
    print("Evidence is aggregate and approximate-token only; raw transcript content is omitted.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect repeated unchanged and oversized tool outputs in a session transcript."
    )
    parser.add_argument("--runtime", choices=("opencode", "claude-code", "normalized"), default="normalized")
    parser.add_argument("--source", required=True, help="SQLite database, JSONL file, or JSONL directory")
    parser.add_argument("--source-format", choices=("auto", "database", "transcript"), default="auto")
    parser.add_argument("--session", default="")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--min-repeat-bytes", type=int, default=80)
    parser.add_argument("--oversized-bytes", type=int, default=8192)
    parser.add_argument("--max-findings", type=int, default=5)
    args = parser.parse_args()
    if args.min_repeat_bytes < 1 or args.oversized_bytes < 1 or args.max_findings < 1:
        parser.error("thresholds and --max-findings must be positive integers")
    return args


def main() -> int:
    args = parse_args()
    source = Path(args.source).expanduser()
    try:
        use_database = args.source_format == "database" or (
            args.source_format == "auto"
            and args.runtime == "opencode"
            and source.is_file()
            and source.suffix == ".db"
        )
        if use_database:
            results, parse_errors = extract_opencode_db(source, args.session)
            source_kind = "database"
        else:
            transcript = resolve_jsonl(source, args.session)
            results, parse_errors = extract_jsonl(transcript)
            source_kind = "transcript"
        report = analyse(
            results=results,
            runtime=args.runtime,
            session_id=args.session,
            source_kind=source_kind,
            parse_errors=parse_errors,
            min_repeat_bytes=args.min_repeat_bytes,
            oversized_bytes=args.oversized_bytes,
            max_findings=args.max_findings,
        )
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    except (OSError, sqlite3.Error):
        print("Error: transcript evidence could not be read", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
