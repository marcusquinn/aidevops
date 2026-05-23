#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render report-ready Markdown/JSON to portable HTML."""

from __future__ import annotations

import html
import json
import sys

from report_render_badges import BADGE_INFERRED
from report_render_badges import BADGE_KEY
from report_render_badges import BADGE_MISSING
from report_render_badges import BADGE_PARTIAL
from report_render_badges import BADGE_VERIFIED
from report_render_json import DETAIL_KEY, SUMMARY_KEY, TITLE_KEY, render_json, validate_json_badges
from report_render_markdown import render_markdown, validate_markdown_badges

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else ""
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
