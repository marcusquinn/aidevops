#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render token-use report artifacts."""

from __future__ import annotations

import html
import json
from pathlib import Path
from typing import Any


def as_dict(report: Any) -> dict[str, Any]:
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


def write_markdown(reports: list[Any], output_dir: Path, generated_at: str) -> Path:
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
        lines.append(_markdown_row(row))
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


def _markdown_row(row: Any) -> str:
    cells = [
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
    return "| " + " | ".join(cells) + " |"


def write_html(reports: list[Any], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.html"
    body = "\n".join(_html_row(row) for row in reports)
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


def _html_row(row: Any) -> str:
    return (
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


def write_json(reports: list[Any], output_dir: Path, generated_at: str) -> Path:
    report_path = output_dir / "report.json"
    payload = {
        "generated_at": generated_at,
        "session_count": len(reports),
        "net_tokens_total": sum(row.net_tokens_total for row in reports),
        "sessions": [as_dict(row) for row in reports],
    }
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report_path
