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
    success: bool | None


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
    metadata = state.get("metadata")
    success = True
    if isinstance(metadata, dict) and isinstance(metadata.get("exit"), int):
        success = metadata["exit"] == 0
    return ToolResult(
        tool=safe_tool_name(part.get("tool")),
        input_value=canonical(state.get("input", {})),
        output=canonical(state.get("output", "")),
        success=success,
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
                        success=record.get("success") if isinstance(record.get("success"), bool) else None,
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
                            success=not bool(item.get("is_error", False)),
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
    row_count = 0
    uri = f"file:{path}?mode=ro"
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
            if not isinstance(part, dict):
                continue
            result = result_from_opencode_part(part)
            if result is not None:
                results.append(result)
    if row_count == 0:
        raise ValueError("session transcript was not found")
    return results, parse_errors


def digest(*values: str) -> str:
    payload = "\0".join(values).encode("utf-8", errors="replace")
    return hashlib.sha256(payload).hexdigest()[:12]


def byte_length(value: str) -> int:
    return len(value.encode("utf-8", errors="replace"))


def receipt_background_bytes(output: str) -> int | None:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, dict) and payload.get("schema") == "aidevops.operation-result/v1":
        evidence = payload.get("evidence")
        if isinstance(evidence, dict) and isinstance(evidence.get("bytes"), int):
            return evidence["bytes"]
    if re.search(r"(?m)^output_id: out_[A-Za-z0-9_]+$", output):
        match = re.search(r"(?m)^evidence: bytes=([0-9]+)\b", output)
        if match:
            return int(match.group(1))
    return None


def repeated_fragment_findings(
    results: list[ToolResult],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    line_groups: dict[tuple[str, str], dict[str, int | str]] = {}
    block_groups: dict[tuple[str, str], dict[str, int | str]] = {}
    for result in results:
        nonempty_lines = [line.rstrip() for line in result.output.splitlines() if line.strip()]
        for line in nonempty_lines:
            size = byte_length(line)
            if size < 40:
                continue
            key = (result.tool, digest(line))
            item = line_groups.setdefault(key, {"tool": result.tool, "count": 0, "bytes": size})
            item["count"] = int(item["count"]) + 1
        for index in range(max(0, len(nonempty_lines) - 2)):
            block = "\n".join(nonempty_lines[index : index + 3])
            size = byte_length(block)
            if size < 120:
                continue
            key = (result.tool, digest(block))
            item = block_groups.setdefault(key, {"tool": result.tool, "count": 0, "bytes": size})
            item["count"] = int(item["count"]) + 1

    line_findings: list[dict[str, Any]] = []
    for (tool, fragment_hash), item in line_groups.items():
        count = int(item["count"])
        if count < 3:
            continue
        redundant_bytes = (count - 1) * int(item["bytes"])
        line_findings.append(
            {
                "kind": "repeated-line",
                "tool": tool,
                "fingerprint": digest(tool, "line", fragment_hash),
                "occurrences": count,
                "redundant_bytes": redundant_bytes,
                "approx_redundant_tokens": math.ceil(redundant_bytes / 4),
            }
        )

    block_findings: list[dict[str, Any]] = []
    for (tool, fragment_hash), item in block_groups.items():
        count = int(item["count"])
        if count < 2:
            continue
        redundant_bytes = (count - 1) * int(item["bytes"])
        block_findings.append(
            {
                "kind": "repeated-block",
                "tool": tool,
                "fingerprint": digest(tool, "block", fragment_hash),
                "occurrences": count,
                "redundant_bytes": redundant_bytes,
                "approx_redundant_tokens": math.ceil(redundant_bytes / 4),
            }
        )

    line_findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    block_findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    return line_findings, block_findings


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
                "kind": "unchanged-snapshot",
                "tool": tool,
                "fingerprint": digest(tool, input_hash, output_hash),
                "occurrences": len(group),
                "redundant_results": redundant,
                "bytes_each": size,
                "redundant_bytes": wasted,
                "approx_redundant_tokens": math.ceil(wasted / 4),
            }
        )

    output_groups: dict[str, list[ToolResult]] = defaultdict(list)
    for result in materialized:
        if byte_length(result.output) >= min_repeat_bytes:
            output_groups[digest(result.output)].append(result)
    duplicate_findings: list[dict[str, Any]] = []
    for output_hash, group in output_groups.items():
        signatures = {(item.tool, digest(item.input_value)) for item in group}
        if len(group) < 2 or len(signatures) < 2:
            continue
        size = byte_length(group[0].output)
        wasted = (len(group) - 1) * size
        tools = {item.tool for item in group}
        duplicate_findings.append(
            {
                "kind": "duplicate-output",
                "tool": "multiple" if len(tools) > 1 else group[0].tool,
                "fingerprint": digest("duplicate", output_hash),
                "occurrences": len(group),
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

    line_findings, block_findings = repeated_fragment_findings(materialized)
    receipt_results = 0
    receipt_model_visible_bytes = 0
    declared_background_evidence_bytes = 0
    raw_fallback_results = 0
    exact_bypass_results = 0
    fallback_groups: dict[str, dict[str, int | str]] = {}
    success_verbosity_groups: dict[tuple[str, str], list[ToolResult]] = defaultdict(list)
    for result in materialized:
        size = byte_length(result.output)
        background_bytes = receipt_background_bytes(result.output)
        if background_bytes is not None:
            receipt_results += 1
            receipt_model_visible_bytes += size
            declared_background_evidence_bytes += background_bytes
        if "output_sandbox: evidence store unavailable; running with native output" in result.output:
            raw_fallback_results += 1
            item = fallback_groups.setdefault(
                result.tool,
                {"tool": result.tool, "count": 0, "bytes": 0},
            )
            item["count"] = int(item["count"]) + 1
            item["bytes"] = int(item["bytes"]) + size
        if "output_sandbox: bypass exact/verbatim command" in result.output:
            exact_bypass_results += 1
        if result.success is True and size >= oversized_bytes:
            success_verbosity_groups[(result.tool, digest(result.output))].append(result)

    fallback_findings = [
        {
            "kind": "raw-fallback",
            "tool": str(item["tool"]),
            "fingerprint": digest(str(item["tool"]), "raw-fallback"),
            "occurrences": int(item["count"]),
            "total_bytes": int(item["bytes"]),
            "approx_total_tokens": math.ceil(int(item["bytes"]) / 4),
        }
        for item in fallback_groups.values()
    ]

    success_verbosity_findings: list[dict[str, Any]] = []
    for (tool, output_hash), group in success_verbosity_groups.items():
        sizes = [byte_length(item.output) for item in group]
        success_verbosity_findings.append(
            {
                "kind": "success-verbosity",
                "tool": tool,
                "fingerprint": digest(tool, "success", output_hash),
                "occurrences": len(group),
                "largest_bytes": max(sizes),
                "total_bytes": sum(sizes),
                "approx_total_tokens": math.ceil(sum(sizes) / 4),
            }
        )

    repeat_findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    duplicate_findings.sort(key=lambda item: (-item["redundant_bytes"], item["tool"]))
    fallback_findings.sort(key=lambda item: (-item["total_bytes"], item["tool"]))
    success_verbosity_findings.sort(key=lambda item: (-item["total_bytes"], item["tool"]))
    oversized_findings.sort(key=lambda item: (-item["total_bytes"], item["tool"]))
    combined = (
        repeat_findings
        + duplicate_findings
        + block_findings
        + line_findings
        + fallback_findings
        + success_verbosity_findings
        + oversized_findings
    )

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
            "duplicate_output_groups": len(duplicate_findings),
            "repeated_line_groups": len(line_findings),
            "repeated_block_groups": len(block_findings),
            "oversized_tool_results": sum(len(group) for group in oversized_groups.values()),
            "successful_oversized_results": sum(len(group) for group in success_verbosity_groups.values()),
            "raw_fallback_results": raw_fallback_results,
            "exact_output_bypass_results": exact_bypass_results,
            "parse_errors": parse_errors,
        },
        "visibility": {
            "model_visible_tool_output_bytes": total_bytes,
            "receipt_results": receipt_results,
            "receipt_model_visible_bytes": receipt_model_visible_bytes,
            "declared_background_evidence_bytes": declared_background_evidence_bytes,
            "background_content_scanned": False,
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
    print(f"Duplicate tool-output groups: {stats['duplicate_output_groups']}")
    print(
        "Repeated line/block groups: "
        f"{stats['repeated_line_groups']}/{stats['repeated_block_groups']}"
    )
    print(
        "Oversized tool results: "
        f"{stats['oversized_tool_results']} "
        f"(threshold {thresholds['oversized_output_bytes']} bytes)"
    )
    print(f"Successful oversized results: {stats['successful_oversized_results']}")
    visibility = report["visibility"]
    print(
        "Receipt-backed background evidence: "
        f"{visibility['declared_background_evidence_bytes']} declared bytes across "
        f"{visibility['receipt_results']} receipts (background content not scanned)"
    )
    print(
        "Raw fallback / exact-output bypass results: "
        f"{stats['raw_fallback_results']} / {stats['exact_output_bypass_results']}"
    )
    if stats["parse_errors"]:
        print(f"Unparsed transcript records: {stats['parse_errors']}")
    print("Candidates:")
    if not report["findings"]:
        print("- None above deterministic thresholds")
    for finding in report["findings"]:
        if finding["kind"] in {"unchanged-snapshot", "duplicate-output", "repeated-line", "repeated-block"}:
            print(
                f"- {finding['kind']} {finding['fingerprint']}: tool={finding['tool']}, "
                f"occurrences={finding['occurrences']}, "
                f"redundant_bytes={finding['redundant_bytes']}"
            )
        else:
            print(
                f"- {finding['kind']} {finding['fingerprint']}: tool={finding['tool']}, "
                f"occurrences={finding['occurrences']}, "
                f"total_bytes={finding.get('total_bytes', finding.get('largest_bytes', 0))}"
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
    if args.session and not re.fullmatch(r"[A-Za-z0-9_.-]+", args.session):
        parser.error("--session may only contain letters, numbers, dots, hyphens, and underscores")
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
