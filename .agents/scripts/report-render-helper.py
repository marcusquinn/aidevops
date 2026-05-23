#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render report-ready Markdown/JSON to portable HTML."""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path

from report_render_badges import BADGE_INFERRED
from report_render_badges import BADGE_KEY
from report_render_badges import BADGE_MISSING
from report_render_badges import BADGE_PARTIAL
from report_render_badges import BADGE_VERIFIED
from report_render_json import DETAIL_KEY, SUMMARY_KEY, TITLE_KEY, render_json, validate_json_badges
from report_render_markdown import render_markdown, validate_markdown_badges
from report_render_styles import style_css, style_names

if len(sys.argv) < 2:
    sys.stderr.write(f"Usage: {sys.argv[0]} <mode> [input]\n")
    sys.exit(1)

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else ""
TEMPLATE = sys.argv[3] if len(sys.argv) > 3 else "basic"
PDF_PROFILE = sys.argv[4] if len(sys.argv) > 4 else "a4"

BASIC_CSS = """
:root { color-scheme: light; --report-paper: #f8f6f1; --report-surface: #fffdf8; --report-ink: #111827; --report-muted: #4b5563; --report-line: #d8d2c4; --report-panel: #fffdf8; --report-blue: #2563eb; --report-green: #147a4a; --report-amber: #b7791f; --report-red: #b42318; }
body.report-body { margin: 0; background: var(--report-paper); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--report-ink); }
.report-shell { display: grid; grid-template-columns: minmax(0, 1fr) minmax(14rem, 18rem); gap: 2rem; max-width: 1180px; margin: 0 auto; padding: 2rem; }
.sticky-toc { position: sticky; top: 1rem; align-self: start; max-height: calc(100vh - 2rem); overflow: auto; border: 1px solid var(--report-line); border-radius: 12px; padding: 1rem; background: var(--report-panel); }
.sticky-toc a { display: block; color: inherit; text-decoration: none; margin: .35rem 0; border-left: 3px solid transparent; padding-left: .5rem; }
.sticky-toc a:hover, .sticky-toc a:focus-visible { border-left-color: var(--report-blue); }
.report-content, .report-main { min-width: 0; }
.badge { display: inline-block; border-radius: 999px; padding: .15rem .55rem; font-size: .78rem; font-weight: 700; border: 1px solid var(--report-line); }
.badge-verified { background: #dcfce7; color: #166534; }
.badge-partial { background: #fef9c3; color: #854d0e; }
.badge-inferred { background: #dbeafe; color: #1e40af; }
.badge-missing { background: #fee2e2; color: #991b1b; }
.source-card { border: 1px solid var(--report-line); border-left: 4px solid var(--report-ink); border-radius: 10px; padding: .85rem 1rem; margin: .75rem 0; background: var(--report-surface); }
table { table-layout: fixed; border-collapse: collapse; width: 100%; margin: 1rem 0; overflow-wrap: anywhere; }
th, td { border: 1px solid var(--report-line); padding: .5rem; text-align: left; vertical-align: top; }
h1, h2, h3 { line-height: 1.15; break-after: avoid; }
@media (max-width: 860px) { .report-shell { display: block; padding: 1rem; } .sticky-toc { position: static; margin-bottom: 1rem; } }
""".strip()

PROFILE_CSS = {
    "a4": "@media print { @page { size: A4 portrait; margin: 12mm 11mm 14mm; } body.report-body { background: #fff; font-size: 10.5pt; } .report-shell { display: block; max-width: none; padding: 0; } .sticky-toc { position: static; break-after: page; box-shadow: none; } table { table-layout: fixed; font-size: 8.8pt; } th,td { padding: 4pt 5pt; } a[href]::after { content: \" (\" attr(href) \")\"; font-size: .85em; overflow-wrap: anywhere; } .sticky-toc a[href]::after, .badge a[href]::after { content: \"\"; } }",
    "letter": "@media print { @page { size: Letter portrait; margin: 0.45in 0.42in 0.52in; } body.report-body { background: #fff; font-size: 10.5pt; } .report-shell { display: block; max-width: none; padding: 0; } .sticky-toc { position: static; break-after: page; box-shadow: none; } table { table-layout: fixed; font-size: 8.6pt; } th,td { padding: 4pt 5pt; } }",
    "slides-16-9-1": "@media print { @page { size: 16in 9in landscape; margin: .35in; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-2": "@media print { @page { size: 16in 9in landscape; margin: .35in; } .report-main { column-count: 2; column-gap: .35in; } .report-main > * { break-inside: avoid; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-3": "@media print { @page { size: 16in 9in landscape; margin: .3in; } .report-main { column-count: 3; column-gap: .3in; } .report-main > * { break-inside: avoid; } .report-shell { display: block; padding: 0; } }",
}

BUILTIN_TEMPLATES = ("basic", "editorial-evidence") + style_names()


def load_css(template: str, pdf_profile: str) -> str:
    css = BASIC_CSS
    if template == "editorial-evidence":
        path = Path(__file__).resolve().parents[1] / "templates" / "reports" / "llm-visibility-report.css"
        css = path.read_text(encoding="utf-8")
    elif template in style_names():
        css = style_css(template)
    elif template != "basic":
        names = ", ".join(BUILTIN_TEMPLATES)
        raise ValueError(f"unknown report template: {template}. Available: {names}")
    if pdf_profile not in PROFILE_CSS:
        raise ValueError(f"unknown PDF export profile: {pdf_profile}")
    return f"{css}\n{PROFILE_CSS[pdf_profile]}"


def read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def wrap_document(headings: list[tuple[int, str, str]], body: str) -> str:
    css = load_css(TEMPLATE, PDF_PROFILE)
    toc_items = []
    for level, title, anchor in headings:
        indent = f' style="margin-left:{max(level - 1, 0)}rem"'
        toc_items.append(f'<li><a href="#{anchor}"{indent}>{html.escape(title)}</a></li>')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Report</title>
<style>{css}</style>
</head>
<body class="report-body report-pdf-profile-{html.escape(PDF_PROFILE)} report-template-{html.escape(TEMPLATE)}">
<div class="report-shell">
<nav class="sticky-toc" aria-label="Report table of contents">
<h2>Contents</h2>
<ol>
{chr(10).join(toc_items)}
</ol>
</nav>
<main class="report-content report-main">
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
        print(load_css(TEMPLATE, PDF_PROFILE))
        return 0
    if MODE == "list-templates":
        print("\n".join(BUILTIN_TEMPLATES))
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
    headings, body = render_json(text) if stripped.startswith(("{", "[")) else render_markdown(text)
    sys.stdout.write(wrap_document(headings, body))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)
