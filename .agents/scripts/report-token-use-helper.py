#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate local token-use reports per AI session."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


DEFAULT_OPENCODE_DB = Path.home() / ".local/share/opencode/opencode.db"
DEFAULT_OBS_DB = Path.home() / ".aidevops/.agent-workspace/observability/llm-requests.db"
DEFAULT_REPORT_ROOT = Path.home() / ".aidevops/_reports/token-use"
DEFAULT_OPENCODE_CONFIG = Path.home() / ".config/opencode/opencode.json"
UTC = timezone.utc


@dataclass
class SessionRow:
    session_id: str
    parent_id: str | None
    title: str
    model: str
    tokens_input: int
    tokens_output: int
    tokens_reasoning: int
    tokens_cache_read: int
    tokens_cache_write: int
    cost: float
    time_created: int
    time_updated: int
    time_compacting: int | None
    directory: str
    path: str
    agent: str


@dataclass
class SessionReport:
    session_id: str
    session_name: str
    runtime: str
    models_used: list[str]
    tokens_input: int
    tokens_output: int
    tokens_reasoning: int
    tokens_cache_read: int
    tokens_cache_write: int
    net_tokens_total: int
    child_session_count: int
    compaction_count: int
    mcps_active: list[str]
    mcps_observed: list[str]
    started_at: str
    finished_at: str
    cost_usd: float
    request_count: int
    tool_call_count: int
    source_session_ids: list[str] = field(default_factory=list)


def _die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def _connect(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone()
    return row is not None


def _parse_since(value: str | None) -> datetime | None:
    if not value:
        return None
    match = re.fullmatch(r"(\d+)([hdw])", value.strip().lower())
    if not match:
        _die("--since must use a duration such as 24h, 7d, or 2w")
    amount = int(match.group(1))
    unit = match.group(2)
    if unit == "h":
        return datetime.now(UTC) - timedelta(hours=amount)
    if unit == "d":
        return datetime.now(UTC) - timedelta(days=amount)
    return datetime.now(UTC) - timedelta(weeks=amount)


def _ms_to_iso(value: int | None) -> str:
    if not value:
        return ""
    return datetime.fromtimestamp(value / 1000, tz=UTC).astimezone().isoformat(timespec="seconds")


def _iso_now_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _safe_title(value: str) -> str:
    cleaned = re.sub(r"\s+", " ", value or "").strip()
    return cleaned[:120] if cleaned else "(untitled)"


def _parse_model(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    if isinstance(data, dict):
        model = data.get("id") or data.get("model") or ""
        provider = data.get("providerID") or data.get("provider") or ""
        variant = data.get("variant") or ""
        parts = [part for part in (provider, model, variant) if part]
        return "/".join(parts)
    return str(data)


def _read_sessions(conn: sqlite3.Connection) -> list[SessionRow]:
    rows = conn.execute(
        """
        SELECT id, parent_id, title, model, tokens_input, tokens_output,
               tokens_reasoning, tokens_cache_read, tokens_cache_write, cost,
               time_created, time_updated, time_compacting, directory, path, agent
        FROM session
        """
    ).fetchall()
    sessions: list[SessionRow] = []
    for row in rows:
        sessions.append(
            SessionRow(
                session_id=row["id"],
                parent_id=row["parent_id"],
                title=row["title"] or "",
                model=row["model"] or "",
                tokens_input=int(row["tokens_input"] or 0),
                tokens_output=int(row["tokens_output"] or 0),
                tokens_reasoning=int(row["tokens_reasoning"] or 0),
                tokens_cache_read=int(row["tokens_cache_read"] or 0),
                tokens_cache_write=int(row["tokens_cache_write"] or 0),
                cost=float(row["cost"] or 0),
                time_created=int(row["time_created"] or 0),
                time_updated=int(row["time_updated"] or 0),
                time_compacting=row["time_compacting"],
                directory=row["directory"] or "",
                path=row["path"] or "",
                agent=row["agent"] or "",
            )
        )
    return sessions


def _root_for(session_id: str, by_id: dict[str, SessionRow]) -> str:
    seen: set[str] = set()
    current = session_id
    while current in by_id and by_id[current].parent_id and current not in seen:
        seen.add(current)
        parent = by_id[current].parent_id
        if not parent or parent not in by_id:
            break
        current = parent
    return current


def _children_by_root(sessions: list[SessionRow]) -> dict[str, list[SessionRow]]:
    by_id = {row.session_id: row for row in sessions}
    grouped: dict[str, list[SessionRow]] = {}
    for row in sessions:
        root = _root_for(row.session_id, by_id)
        grouped.setdefault(root, []).append(row)
    return grouped


def _configured_mcps() -> list[str]:
    config_path = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG", DEFAULT_OPENCODE_CONFIG))
    if not config_path.exists():
        return []
    text = config_path.read_text(encoding="utf-8", errors="replace")
    text = _strip_jsonc_comments(text)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    mcp = data.get("mcp") if isinstance(data, dict) else None
    if isinstance(mcp, dict):
        return sorted(str(key) for key in mcp.keys())
    return []


def _strip_jsonc_comments(text: str) -> str:
    output: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == "/" and next_char == "/":
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            continue
        if char == "/" and next_char == "*":
            index += 2
            while index + 1 < len(text) and not (text[index] == "*" and text[index + 1] == "/"):
                index += 1
            index += 2
            continue
        output.append(char)
        index += 1
    return "".join(output)


def _model_switches(conn: sqlite3.Connection, session_ids: list[str]) -> set[str]:
    if not _table_exists(conn, "session_message") or not session_ids:
        return set()
    placeholders = ",".join("?" for _ in session_ids)
    rows = conn.execute(
        f"SELECT data FROM session_message WHERE type='model-switched' AND session_id IN ({placeholders})",
        session_ids,
    ).fetchall()
    models: set[str] = set()
    for row in rows:
        try:
            data = json.loads(row["data"] or "{}")
        except json.JSONDecodeError:
            continue
        model = data.get("model") if isinstance(data, dict) else None
        if isinstance(model, dict):
            mid = model.get("id") or ""
            provider = model.get("providerID") or ""
            variant = model.get("variant") or ""
            rendered = "/".join(part for part in (provider, mid, variant) if part)
            if rendered:
                models.add(rendered)
    return models


def _mcp_name_from_tool(tool: str, configured_mcps: list[str]) -> str:
    if tool.startswith("mcp_"):
        remainder = tool[4:]
        return remainder.split("_", 1)[0] if remainder else tool
    for name in configured_mcps:
        normalized = name.replace("-", "_")
        if tool.startswith(f"{normalized}_") or tool.startswith(f"{name}_"):
            return name
    return ""


def _observability_for(obs_db: Path, session_ids: list[str], configured_mcps: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {"models": set(), "requests": 0, "tool_calls": 0, "observed_mcps": set()}
    conn = _connect(obs_db)
    if conn is None:
        return result
    try:
        placeholders = ",".join("?" for _ in session_ids)
        if placeholders and _table_exists(conn, "llm_requests"):
            for row in conn.execute(
                f"SELECT model_id, COUNT(*) AS n FROM llm_requests WHERE session_id IN ({placeholders}) GROUP BY model_id",
                session_ids,
            ):
                if row["model_id"]:
                    result["models"].add(str(row["model_id"]))
                result["requests"] += int(row["n"] or 0)
        if placeholders and _table_exists(conn, "tool_calls"):
            for row in conn.execute(
                f"SELECT tool_name, COUNT(*) AS n FROM tool_calls WHERE session_id IN ({placeholders}) GROUP BY tool_name",
                session_ids,
            ):
                tool = str(row["tool_name"] or "")
                result["tool_calls"] += int(row["n"] or 0)
                mcp_name = _mcp_name_from_tool(tool, configured_mcps)
                if mcp_name:
                    result["observed_mcps"].add(mcp_name)
    finally:
        conn.close()
    return result


def _opencode_reports(args: argparse.Namespace) -> list[SessionReport]:
    db_path = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB", DEFAULT_OPENCODE_DB))
    obs_db = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_OBS_DB", DEFAULT_OBS_DB))
    conn = _connect(db_path)
    if conn is None:
        return []
    try:
        sessions = _read_sessions(conn)
        grouped = _children_by_root(sessions)
        by_id = {row.session_id: row for row in sessions}
        since_dt = _parse_since(args.since)
        since_ms = int(since_dt.timestamp() * 1000) if since_dt else None
        configured_mcps = _configured_mcps()
        reports: list[SessionReport] = []
        for root_id, group in grouped.items():
            if args.session and args.session not in [row.session_id for row in group]:
                continue
            if since_ms and max(row.time_updated for row in group) < since_ms:
                continue
            root = by_id.get(root_id, group[0])
            session_ids = [row.session_id for row in group]
            obs = _observability_for(obs_db, session_ids, configured_mcps)
            models = {model for model in (_parse_model(row.model) for row in group) if model}
            models.update(_model_switches(conn, session_ids))
            models.update(obs["models"])
            tokens_input = sum(row.tokens_input for row in group)
            tokens_output = sum(row.tokens_output for row in group)
            tokens_reasoning = sum(row.tokens_reasoning for row in group)
            tokens_cache_read = sum(row.tokens_cache_read for row in group)
            tokens_cache_write = sum(row.tokens_cache_write for row in group)
            reports.append(
                SessionReport(
                    session_id=root_id,
                    session_name=_safe_title(root.title),
                    runtime="opencode",
                    models_used=sorted(models) or ["unknown"],
                    tokens_input=tokens_input,
                    tokens_output=tokens_output,
                    tokens_reasoning=tokens_reasoning,
                    tokens_cache_read=tokens_cache_read,
                    tokens_cache_write=tokens_cache_write,
                    net_tokens_total=tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write,
                    child_session_count=max(len(group) - 1, 0),
                    compaction_count=sum(1 for row in group if row.parent_id or row.time_compacting),
                    mcps_active=configured_mcps,
                    mcps_observed=sorted(obs["observed_mcps"]),
                    started_at=_ms_to_iso(min(row.time_created for row in group)),
                    finished_at=_ms_to_iso(max(row.time_updated for row in group)),
                    cost_usd=round(sum(row.cost for row in group), 6),
                    request_count=int(obs["requests"]),
                    tool_call_count=int(obs["tool_calls"]),
                    source_session_ids=sorted(session_ids),
                )
            )
        reports.sort(key=lambda row: row.finished_at, reverse=True)
        return reports[: args.limit]
    finally:
        conn.close()


def _claude_reports(args: argparse.Namespace) -> list[SessionReport]:
    metrics_path = Path.home() / ".aidevops/.agent-workspace/observability/metrics.jsonl"
    if not metrics_path.exists():
        return []
    since_dt = _parse_since(args.since)
    grouped: dict[str, dict[str, Any]] = {}
    with metrics_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = row.get("session_id") or "unknown"
            if args.session and args.session != session_id:
                continue
            recorded_at = row.get("recorded_at") or ""
            if since_dt and recorded_at:
                try:
                    ts = datetime.fromisoformat(recorded_at.replace("Z", "+00:00"))
                except ValueError:
                    ts = None
                if ts and ts < since_dt:
                    continue
            data = grouped.setdefault(
                session_id,
                {"models": set(), "input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "first": recorded_at, "last": recorded_at, "requests": 0},
            )
            if row.get("model"):
                data["models"].add(str(row["model"]))
            data["input"] += int(row.get("input_tokens") or 0)
            data["output"] += int(row.get("output_tokens") or 0)
            data["cache_read"] += int(row.get("cache_read_tokens") or 0)
            data["cache_write"] += int(row.get("cache_write_tokens") or 0)
            data["cost"] += float(row.get("cost_total") or 0)
            data["requests"] += 1
            data["first"] = min(filter(None, [data["first"], recorded_at]), default="")
            data["last"] = max(filter(None, [data["last"], recorded_at]), default="")
    reports: list[SessionReport] = []
    for session_id, data in grouped.items():
        reports.append(
            SessionReport(
                session_id=session_id,
                session_name=session_id,
                runtime="claude",
                models_used=sorted(data["models"]) or ["unknown"],
                tokens_input=data["input"],
                tokens_output=data["output"],
                tokens_reasoning=0,
                tokens_cache_read=data["cache_read"],
                tokens_cache_write=data["cache_write"],
                net_tokens_total=data["input"] + data["output"] + data["cache_read"] + data["cache_write"],
                child_session_count=0,
                compaction_count=0,
                mcps_active=[],
                mcps_observed=[],
                started_at=data["first"],
                finished_at=data["last"],
                cost_usd=round(data["cost"], 6),
                request_count=data["requests"],
                tool_call_count=0,
                source_session_ids=[session_id],
            )
        )
    reports.sort(key=lambda row: row.finished_at, reverse=True)
    return reports[: args.limit]


def _collect_reports(args: argparse.Namespace) -> list[SessionReport]:
    if args.runtime == "opencode":
        return _opencode_reports(args)
    if args.runtime == "claude":
        return _claude_reports(args)
    reports = _opencode_reports(args)
    return reports if reports else _claude_reports(args)


def _as_dict(report: SessionReport) -> dict[str, Any]:
    return {
        "session_id": report.session_id,
        "session_name": report.session_name,
        "runtime": report.runtime,
        "models_used": report.models_used,
        "tokens_input": report.tokens_input,
        "tokens_output": report.tokens_output,
        "tokens_reasoning": report.tokens_reasoning,
        "tokens_cache_read": report.tokens_cache_read,
        "tokens_cache_write": report.tokens_cache_write,
        "net_tokens_total": report.net_tokens_total,
        "child_session_count": report.child_session_count,
        "compaction_count": report.compaction_count,
        "mcps_active": report.mcps_active,
        "mcps_observed": report.mcps_observed,
        "started_at": report.started_at,
        "finished_at": report.finished_at,
        "cost_usd": report.cost_usd,
        "request_count": report.request_count,
        "tool_call_count": report.tool_call_count,
        "source_session_ids": report.source_session_ids,
    }


def _format_int(value: int) -> str:
    return f"{value:,}"


def _write_markdown(reports: list[SessionReport], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.md"
    total = sum(row.net_tokens_total for row in reports)
    lines = [
        "# Token Use Report",
        "",
        f"Generated: {generated_at}",
        f"Sessions: {len(reports)}",
        f"Net tokens: {_format_int(total)}",
        "",
        "| Session name | Runtime | Models | Tokens in | Tokens out | Cached-read | Net total | Compactions | MCPs active | MCPs observed | Started | Finished |",
        "|---|---|---|---:|---:|---:|---:|---:|---|---|---|---|",
    ]
    for row in reports:
        lines.append(
            "| "
            + " | ".join(
                [
                    row.session_name.replace("|", "\\|"),
                    row.runtime,
                    ", ".join(row.models_used).replace("|", "\\|"),
                    _format_int(row.tokens_input),
                    _format_int(row.tokens_output),
                    _format_int(row.tokens_cache_read),
                    _format_int(row.net_tokens_total),
                    str(row.compaction_count),
                    ", ".join(row.mcps_active) or "none configured",
                    ", ".join(row.mcps_observed) or "none observed",
                    row.started_at,
                    row.finished_at,
                ]
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- Net total is input + output + reasoning + cache-read + cache-write tokens.",
            "- OpenCode rows recursively include child sessions via `session.parent_id` so compacted sessions are counted with their root session.",
            "- MCPs active are configured OpenCode MCP server names at report time; MCPs observed are inferred from session tool-call names when available.",
        ]
    )
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report_path


def _write_html(reports: list[SessionReport], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.html"
    rows = []
    for row in reports:
        rows.append(
            "<tr>"
            f"<td>{html.escape(row.session_name)}</td>"
            f"<td>{html.escape(row.runtime)}</td>"
            f"<td>{html.escape(', '.join(row.models_used))}</td>"
            f"<td>{_format_int(row.tokens_input)}</td>"
            f"<td>{_format_int(row.tokens_output)}</td>"
            f"<td>{_format_int(row.tokens_cache_read)}</td>"
            f"<td>{_format_int(row.net_tokens_total)}</td>"
            f"<td>{row.compaction_count}</td>"
            f"<td>{html.escape(', '.join(row.mcps_active) or 'none configured')}</td>"
            f"<td>{html.escape(', '.join(row.mcps_observed) or 'none observed')}</td>"
            f"<td>{html.escape(row.started_at)}</td>"
            f"<td>{html.escape(row.finished_at)}</td>"
            "</tr>"
        )
    body = "\n".join(rows)
    total = _format_int(sum(row.net_tokens_total for row in reports))
    html_doc = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>Token Use Report</title>
  <style>
    body {{ color: #172033; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border-bottom: 1px solid #d8dee9; padding: .55rem; text-align: left; vertical-align: top; }}
    td:nth-child(4), td:nth-child(5), td:nth-child(6), td:nth-child(7), td:nth-child(8) {{ text-align: right; }}
    th {{ background: #f5f7fb; position: sticky; top: 0; }}
    .meta {{ color: #5f6b7a; }}
  </style>
</head>
<body>
  <h1>Token Use Report</h1>
  <p class=\"meta\">Generated: {html.escape(generated_at)} · Sessions: {len(reports)} · Net tokens: {total}</p>
  <table>
    <thead><tr><th>Session name</th><th>Runtime</th><th>Models</th><th>Tokens in</th><th>Tokens out</th><th>Cached-read</th><th>Net total</th><th>Compactions</th><th>MCPs active</th><th>MCPs observed</th><th>Started</th><th>Finished</th></tr></thead>
    <tbody>
{body}
    </tbody>
  </table>
</body>
</html>
"""
    report_path.write_text(html_doc, encoding="utf-8")
    return report_path


def _write_json(reports: list[SessionReport], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.json"
    payload = {
        "generated_at": generated_at,
        "session_count": len(reports),
        "net_tokens_total": sum(row.net_tokens_total for row in reports),
        "sessions": [_as_dict(row) for row in reports],
    }
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report_path


def _open_path(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.run(["open", str(path)], check=False)
    elif os.name == "nt":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        subprocess.run(["xdg-open", str(path)], check=False)


def _add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--limit", type=int, default=25, help="maximum sessions to include")
    parser.add_argument("--session", help="include one session/root session")
    parser.add_argument("--since", help="restrict to sessions updated within duration, e.g. 24h, 7d, 2w")
    parser.add_argument("--runtime", choices=["auto", "opencode", "claude"], default="auto")


def cmd_data(args: argparse.Namespace) -> int:
    reports = _collect_reports(args)
    payload = {"sessions": [_as_dict(row) for row in reports]}
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    reports = _collect_reports(args)
    generated_at = datetime.now(UTC).astimezone().isoformat(timespec="seconds")
    output_root = Path(os.environ.get("AIDEVOPS_REPORT_TOKEN_USE_ROOT", DEFAULT_REPORT_ROOT))
    output_dir = output_root / _iso_now_id()
    output_dir.mkdir(parents=True, exist_ok=True)
    md_path = _write_markdown(reports, output_dir, generated_at)
    json_path = _write_json(reports, output_dir, generated_at)
    html_path = _write_html(reports, output_dir, generated_at)
    if args.open:
        _open_path(html_path)
    if args.json:
        print(
            json.dumps(
                {
                    "report_md": str(md_path),
                    "report_json": str(json_path),
                    "report_html": str(html_path),
                    "report_url": html_path.resolve().as_uri(),
                },
                indent=2,
            )
        )
    else:
        print(f"Report written: {html_path.resolve().as_uri()}")
        print(f"Markdown: {md_path}")
        print(f"JSON: {json_path}")
        print(f"Sessions: {len(reports)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    report_parser = subparsers.add_parser("report", help="write Markdown, JSON, and HTML report files")
    _add_common_args(report_parser)
    report_parser.add_argument("--json", action="store_true", help="print artifact paths as JSON")
    report_parser.add_argument("--open", action="store_true", help="open the generated HTML report")
    report_parser.set_defaults(func=cmd_report)
    data_parser = subparsers.add_parser("data", help="print raw session report data as JSON")
    _add_common_args(data_parser)
    data_parser.add_argument("--json", action="store_true", help="accepted for command symmetry")
    data_parser.set_defaults(func=cmd_data)
    args = parser.parse_args(argv)
    if args.limit < 1:
        _die("--limit must be positive")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
