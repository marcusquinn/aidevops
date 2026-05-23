#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render report-ready Markdown/JSON to portable HTML."""

from __future__ import annotations

import html
import json
import re
import sys
from typing import Any

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else ""
BADGE_VERIFIED = "verified"
BADGE_PARTIAL = "partial"
BADGE_INFERRED = "inferred"
BADGE_MISSING = "missing"
BADGE_KEY = "evidence_badge"
TITLE_KEY = "title"
DETAIL_KEY = "detail"
SUMMARY_KEY = "summary"
ALLOWED_BADGES = (BADGE_VERIFIED, BADGE_PARTIAL, BADGE_INFERRED, BADGE_MISSING)
BADGE_LABELS = {
    BADGE_VERIFIED: "Evidence: Verified",
    BADGE_PARTIAL: "Evidence: Partial",
    BADGE_INFERRED: "Evidence: Inferred",
    BADGE_MISSING: "Evidence: Missing",
}

CSS = """
:root { color-scheme: light; --ink: #1f2937; --muted: #6b7280; --line: #d1d5db; --panel: #f9fafb; }
body { margin: 0; font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--ink); }
.report-shell { display: grid; grid-template-columns: minmax(14rem, 18rem) minmax(0, 1fr); gap: 2rem; max-width: 1180px; margin: 0 auto; padding: 2rem; }
.sticky-toc { position: sticky; top: 1rem; align-self: start; max-height: calc(100vh - 2rem); overflow: auto; border: 1px solid var(--line); border-radius: 12px; padding: 1rem; background: var(--panel); }
.sticky-toc a { display: block; color: inherit; text-decoration: none; margin: .35rem 0; }
.report-content { min-width: 0; }
.badge { display: inline-block; border-radius: 999px; padding: .15rem .55rem; font-size: .78rem; font-weight: 700; border: 1px solid var(--line); }
.badge-verified { background: #dcfce7; color: #166534; }
.badge-partial { background: #fef9c3; color: #854d0e; }
.badge-inferred { background: #dbeafe; color: #1e40af; }
.badge-missing { background: #fee2e2; color: #991b1b; }
.source-card { border: 1px solid var(--line); border-left: 4px solid #111827; border-radius: 10px; padding: .85rem 1rem; margin: .75rem 0; background: #fff; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
th, td { border: 1px solid var(--line); padding: .5rem; text-align: left; }
@media print { .report-shell { display: block; padding: 0; } .sticky-toc { position: static; page-break-after: always; } a { color: inherit; } }
""".strip()


def read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def slug(text: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return value or "section"


def badge_html(value: Any) -> str:
    key = str(value).strip().lower()
    if key not in ALLOWED_BADGES:
        raise ValueError(f"unknown evidence badge value: {value}")
    return f'<span class="badge badge-{key}">{BADGE_LABELS[key]}</span>'


def validate_json_badges(node: Any) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key in (BADGE_KEY, "evidenceBadge"):
                badge_html(value)
            validate_json_badges(value)
    elif isinstance(node, list):
        for item in node:
            validate_json_badges(item)


def validate_markdown_badges(text: str) -> None:
    for match in re.finditer(r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}", text, re.I):
        badge_html(match.group(1))


def inline_markup(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(
        r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}",
        lambda match: badge_html(html.unescape(match.group(1))),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)


def close_blocks(body: list[str], states: dict[str, bool]) -> None:
    if states["list"]:
        body.append("</ul>")
        states["list"] = False
    if states["table"]:
        body.append("</tbody></table>")
        states["table"] = False


def handle_markdown_line(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: dict[str, bool],
) -> None:
    heading = re.match(r"^(#{1,3})\s+(.+)$", line)
    if heading:
        close_blocks(body, states)
        level = len(heading.group(1))
        title = heading.group(2).strip()
        anchor = slug(title)
        headings.append((level, title, anchor))
        body.append(f'<h{level} id="{anchor}">{inline_markup(title)}</h{level}>')
        return
    if line.startswith("|") and line.endswith("|"):
        cells = [inline_markup(cell.strip()) for cell in line.strip("|").split("|")]
        raw_cells = [html.unescape(cell) for cell in cells]
        if all(re.match(r"^:?-{3,}:?$", cell) for cell in raw_cells):
            return
        if not states["table"]:
            close_blocks(body, states)
            body.append("<table><tbody>")
            states["table"] = True
        body.append("<tr>{}</tr>".format("".join(f"<td>{cell}</td>" for cell in cells)))
        return
    if line.startswith(("- ", "* ")):
        if not states["list"]:
            close_blocks(body, states)
            body.append("<ul>")
            states["list"] = True
        body.append(f"<li>{inline_markup(line[2:].strip())}</li>")
        return
    close_blocks(body, states)
    if line.lower().startswith(("source:", "source card:")):
        body.append(f'<aside class="source-card">{inline_markup(line)}</aside>')
    else:
        body.append(f"<p>{inline_markup(line)}</p>")


def render_markdown(text: str) -> tuple[list[tuple[int, str, str]], str]:
    validate_markdown_badges(text)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    states = {"list": False, "table": False}
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line:
            handle_markdown_line(line, headings, body, states)
        else:
            close_blocks(body, states)
    close_blocks(body, states)
    return headings, "\n".join(body)


def render_json(text: str) -> tuple[list[tuple[int, str, str]], str]:
    data = json.loads(text)
    validate_json_badges(data)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    title = data.get(TITLE_KEY, "Report") if isinstance(data, dict) else "Report"
    headings.append((1, title, slug(title)))
    body.append(f'<h1 id="{slug(title)}">{inline_markup(title)}</h1>')
    for section in data.get("sections", []):
        section_title = section.get(TITLE_KEY, "Section")
        headings.append((2, section_title, slug(section_title)))
        body.append(f'<h2 id="{slug(section_title)}">{inline_markup(section_title)}</h2>')
        if section.get(SUMMARY_KEY):
            body.append(f"<p>{inline_markup(str(section[SUMMARY_KEY]))}</p>")
        for item in section.get("items", []):
            badge = f" {badge_html(item[BADGE_KEY])}" if item.get(BADGE_KEY) else ""
            item_title = inline_markup(str(item.get(TITLE_KEY, "Item")))
            detail = inline_markup(str(item.get(DETAIL_KEY, "")))
            body.append(f'<div class="source-card"><strong>{item_title}</strong>{badge}<p>{detail}</p></div>')
    return headings, "\n".join(body)


def wrap_document(headings: list[tuple[int, str, str]], body: str) -> str:
    toc_items = []
    for level, title, anchor in headings:
        indent = f' style="margin-left:{max(level - 1, 0)}rem"'
        toc_items.append(f'<a href="#{anchor}"{indent}>{html.escape(title)}</a>')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Report</title>
<style>{CSS}</style>
</head>
<body>
<div class="report-shell">
<nav class="sticky-toc" aria-label="Report table of contents">
<strong>Contents</strong>
{chr(10).join(toc_items)}
</nav>
<main class="report-content">
{body}
</main>
</div>
</body>
</html>
"""


def sample_json() -> str:
    return json.dumps(
        {
            TITLE_KEY: "AI Visibility Report",
            "sections": [
                {
                    TITLE_KEY: "Executive summary",
                    SUMMARY_KEY: "Visibility improved across answer engines.",
                    "items": [
                        {TITLE_KEY: "AIO", DETAIL_KEY: "Cited with source card.", BADGE_KEY: BADGE_VERIFIED},
                        {TITLE_KEY: "Gemini", DETAIL_KEY: "Partial coverage found.", BADGE_KEY: BADGE_PARTIAL},
                        {TITLE_KEY: "ChatGPT", DETAIL_KEY: "Inference from comparable prompts.", BADGE_KEY: BADGE_INFERRED},
                        {TITLE_KEY: "Perplexity", DETAIL_KEY: "No citation found.", BADGE_KEY: BADGE_MISSING},
                    ],
                }
            ],
        },
        indent=2,
    )


def main() -> int:
    if MODE == "print-css":
        print(CSS)
        return 0
    if MODE == "sample-json":
        print(sample_json())
        return 0
    text = read_input(INPUT)
    if MODE == "validate":
        stripped = text.lstrip()
        if stripped.startswith(("{", "[")):
            validate_json_badges(json.loads(text))
        else:
            validate_markdown_badges(text)
        return 0
    stripped = text.lstrip()
    headings, body = render_json(text) if stripped.startswith("{") else render_markdown(text)
    sys.stdout.write(wrap_document(headings, body))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)
