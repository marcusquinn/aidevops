#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Render report-ready Markdown/JSON to portable HTML."""

from __future__ import annotations

import html
import json
import os
import re
import sys
from pathlib import Path

from report_render_badges import BADGE_INFERRED
from report_render_badges import BADGE_KEY
from report_render_badges import BADGE_MISSING
from report_render_badges import BADGE_PARTIAL
from report_render_badges import BADGE_VERIFIED
from report_render_json import DETAIL_KEY, SUMMARY_KEY, TITLE_KEY, render_json, validate_json_badges
from report_render_markup import inline_markup
from report_render_markdown import render_action_prompt_markdown, render_markdown, validate_markdown_badges
from report_render_styles import dark_style_names, style_css, style_names

if len(sys.argv) < 2:
    sys.stderr.write(f"Usage: {sys.argv[0]} <mode> [input]\n")
    sys.exit(1)

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else "-"
TEMPLATE = sys.argv[3] if len(sys.argv) > 3 else "basic"
PDF_PROFILE = sys.argv[4] if len(sys.argv) > 4 else "a4"
THEME = sys.argv[5] if len(sys.argv) > 5 else "auto"

BASIC_CSS = """
:root { color-scheme: light; --report-paper: #ffffff; --report-paper-raised: #f8fafc; --report-surface: #ffffff; --report-ink: #111827; --report-ink-soft: #4b5563; --report-muted: #4b5563; --report-line: #d1d5db; --report-rule: #d1d5db; --report-panel: #ffffff; --report-blue: #2563eb; --report-green: #147a4a; --report-amber: #b7791f; --report-red: #b42318; --report-code-bg: #f8fafc; --report-code-ink: #111827; --report-code-accent: #1d4ed8; --report-radius-md: 8px; --report-badge-radius: 4px; }
body.report-body { margin: 0; background: var(--report-paper); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--report-ink); }
body.report-theme-dark { color-scheme: dark; --report-paper: #0f172a; --report-paper-raised: #111827; --report-surface: #111827; --report-panel: #111827; --report-ink: #f8fafc; --report-ink-soft: #cbd5e1; --report-muted: #cbd5e1; --report-line: #334155; --report-rule: #334155; --report-code-bg: #020617; --report-code-ink: #e5e7eb; --report-code-accent: #93c5fd; }
.report-shell { max-width: 1120px; margin: 0 auto; padding: 2rem; }
.report-main { min-width: 0; }
.sticky-toc { margin: 0 0 2rem; overflow: hidden; border: 1px solid var(--report-line); border-radius: 10px; padding: 1rem; background: var(--report-panel); }
.sticky-toc-header { display: flex; gap: 1rem; align-items: center; justify-content: space-between; margin-bottom: 1rem; padding-right: .35rem; }
.toc-pdf-actions { display: inline-flex; flex: 0 0 auto; gap: .5rem; align-items: center; }
.toc-pdf-link { display: inline-flex; min-inline-size: 3.2rem; height: 2rem; align-items: center; justify-content: center; align-self: center; flex: 0 0 auto; box-sizing: border-box; padding: 0 .7rem; border: 1.5px solid var(--report-line); border-radius: var(--report-badge-radius); background: var(--report-panel); color: inherit; font-size: .72rem; font-weight: 900; letter-spacing: .08em; line-height: 1 !important; text-align: center; text-decoration: none !important; white-space: nowrap; }
.sticky-toc ol { max-height: calc(100vh - 9rem); overflow: auto; margin: 0; padding: 0; padding-right: .25rem; list-style: none; }
.sticky-toc ol a { display: block; color: inherit; font-size: .875rem; line-height: 1.45; text-decoration: none; }
.sticky-toc ol a:hover, .sticky-toc ol a:focus-visible { text-decoration: underline; }
.report-content, .report-main { min-width: 0; }
.badge-row, .appendix-links, .anchor-links { display: flex; flex-wrap: wrap; gap: 1rem; line-height: 1.35; }
.appendix-links, .anchor-links { justify-content: center; }
.appendix-links p, .anchor-links p { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; justify-content: center; margin: 0; }
.anchor-links a, .appendix-links a { border-radius: var(--report-badge-radius); box-shadow: inset 0 -.16em 0 color-mix(in srgb, var(--report-blue) 18%, transparent); }
.badge { display: inline-flex; width: fit-content; min-width: max-content; max-width: 100%; white-space: nowrap; border-radius: var(--report-badge-radius); padding: .15rem .55rem; font-size: .78rem; font-weight: 700; border: 1px solid var(--report-line); }
.badge-verified { background: #dcfce7; color: #166534; }
.badge-partial { background: #fef9c3; color: #854d0e; }
.badge-inferred { background: #dbeafe; color: #1e40af; }
.badge-missing { background: #fee2e2; color: #991b1b; }
.source-card, .source-item { position: relative; padding-right: 3.75rem; }
.source-card { border: 1px solid var(--report-line); border-left: 4px solid var(--report-ink); border-radius: 10px; padding: .85rem 3.75rem .85rem 1rem; margin: .75rem 0; background: var(--report-surface); }
.source-card-link { position: absolute; inset: 0; z-index: 2; display: block; border-radius: inherit; color: var(--report-blue); text-decoration: none; }
.source-card-link::before { content: "↗"; position: absolute; top: 1rem; right: 1rem; display: inline-flex; width: 1.6rem; height: 1.6rem; align-items: center; justify-content: center; border: 1px solid var(--report-line); border-radius: var(--report-badge-radius); background: var(--report-surface); font-weight: 900; line-height: 1; }
.source-card-link[href]::after { content: "" !important; }
.code-block-wrap, .mermaid-rendered, .latex-rendered-block { max-width: 100%; min-width: 0; margin: 1rem 0; border: 1px solid var(--report-line); border-radius: 10px; overflow: hidden; background: var(--report-code-bg); color: var(--report-code-ink); }
.code-block-head { display: flex; gap: 1rem; align-items: center; justify-content: space-between; padding: .45rem .75rem; border-bottom: 1px solid var(--report-line); color: var(--report-code-accent); font: 700 .78rem/1.3 ui-monospace, SFMono-Regular, Consolas, monospace; }
.code-copy { display: inline-grid; width: 1.75rem; height: 1.75rem; place-items: center; border: 1px solid var(--report-line); border-radius: 999px; background: transparent; color: inherit; cursor: pointer; }
.code-copy.is-copied { background: var(--report-green); border-color: var(--report-green); color: #ffffff; }
.version-summary { color: var(--report-muted); font-size: clamp(.72rem, .58rem + .42vw, .92rem); font-weight: 800; letter-spacing: .11em; line-height: 1.42; text-align: left; text-transform: uppercase; }
.version-summary p { max-width: none; margin: 0; }
.code-block-wrap pre { max-width: 100%; margin: 0; padding: .8rem .8rem .8rem 1rem; overflow-x: auto; }
.action-prompt { width: 100%; max-width: 100%; min-width: 0; overflow: hidden; }
.action-prompt pre { white-space: pre-wrap; overflow-wrap: anywhere; }
.mermaid-rendered, .latex-rendered-block { padding: 1rem; }
.mermaid-rendered svg { width: 100%; height: auto; }
.diagram-node { fill: var(--report-paper-raised); stroke: var(--report-blue); stroke-width: 2; }
.diagram-label { fill: var(--report-ink); font: 700 14px system-ui, sans-serif; }
.diagram-arrow { stroke: var(--report-blue); stroke-width: 2.5; marker-end: url(#arrowhead); }
.diagram-arrow-head { fill: var(--report-blue); }
.latex-rendered-block div, .latex-inline { color: var(--report-code-ink); }
.mermaid-rendered figcaption, .latex-rendered-block figcaption { color: var(--report-ink-soft); }
table { table-layout: auto; border-collapse: collapse; width: 100%; margin: 1rem 0; overflow-wrap: normal; }
th, td { border: 1px solid var(--report-line); padding: .5rem; text-align: left; vertical-align: top; }
h1, h2, h3 { line-height: 1.15; break-after: avoid; }
.report-footer { max-width: 1180px; margin: 0 auto; padding: 1rem 2rem 2rem; color: var(--report-muted); font-size: .875rem; text-align: center; }
@media (max-width: 860px) { .report-shell { display: block; padding: 1rem; } .sticky-toc { position: static; margin-bottom: 1rem; } }
""".strip()

PROFILE_CSS = {
    "a4": "@media print { @page { size: A4 portrait; margin: 12mm; } html, body.report-body { background: var(--report-paper) !important; font-size: 10.5pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-body { min-height: 100vh; padding: 0; } body.report-theme-dark { background: var(--report-paper) !important; } .report-shell { display: block; max-width: none; padding: 0; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } .sticky-toc { position: static; max-height: none; overflow: visible; break-after: page; break-inside: auto; border: 0; border-radius: 0; box-shadow: none; } .sticky-toc ol { display: block; max-height: none; overflow: visible; padding-right: 0; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } table { table-layout: fixed; font-size: 8.8pt; border-collapse: separate; border-spacing: 0; } th { background: color-mix(in srgb, var(--report-blue) 12%, var(--report-surface)); } th,td { padding: 4pt 5pt; overflow-wrap: anywhere; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } a[href]::after { content: \" (\" attr(href) \")\"; font-size: .85em; overflow-wrap: anywhere; } .sticky-toc a[href]::after, .badge a[href]::after, .source-card-link[href]::after, .anchor-links a[href]::after { content: \"\"; } .appendix-links a[href]::after { content: attr(data-filetype); } }",
    "letter": "@media print { @page { size: Letter portrait; margin: .45in; } html, body.report-body { background: var(--report-paper) !important; font-size: 10.5pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-body { min-height: 100vh; padding: 0; } body.report-theme-dark { background: var(--report-paper) !important; } .report-shell { display: block; max-width: none; padding: 0; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } .sticky-toc { position: static; max-height: none; overflow: visible; break-after: page; break-inside: auto; border: 0; border-radius: 0; box-shadow: none; } .sticky-toc ol { display: block; max-height: none; overflow: visible; padding-right: 0; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } table { table-layout: fixed; font-size: 8.6pt; border-collapse: separate; border-spacing: 0; } th { background: color-mix(in srgb, var(--report-blue) 12%, var(--report-surface)); } th,td { padding: 4pt 5pt; overflow-wrap: anywhere; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } }",
    "slides-16-9-1": "@media print { @page { size: 16in 9in; margin: .35in; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-2": "@media print { @page { size: 16in 9in; margin: .35in; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-main { column-count: 2; column-gap: .35in; } .report-main > * { break-inside: avoid; } .report-shell { display: block; padding: 0; } }",
    "slides-16-9-3": "@media print { @page { size: 16in 9in; margin: .3in; } html, body.report-body { width: auto; min-height: auto; box-sizing: border-box; background: var(--report-paper) !important; padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; } body.report-theme-dark { background: var(--report-paper) !important; } h1,h2,h3,.code-block-head,.source-title { break-after: avoid; page-break-after: avoid; } .code-block-wrap,.mermaid-rendered,.latex-rendered-block,.bar-chart p { break-inside: avoid; page-break-inside: avoid; } pre,.mermaid,.latex-block { overflow-x: visible; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; } .sticky-toc { max-height: none; overflow: visible; break-inside: auto; border: 0; border-radius: 0; } .sticky-toc ol { max-height: none; overflow: visible; } .toc-pdf-actions, .toc-pdf-link { display: none !important; } .report-main { column-count: 3; column-gap: .3in; } .report-main > * { break-inside: avoid; } .report-shell { display: block; padding: 0; } }",
}

BUILTIN_TEMPLATES = ("basic", "editorial-evidence") + style_names()
THEMES = ("auto", "light", "dark")


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
    if THEME not in THEMES:
        raise ValueError(f"unknown report theme: {THEME}. Available: {', '.join(THEMES)}")
    return f"{css}\n{PROFILE_CSS[pdf_profile]}"


def read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def toc_title(title: str) -> str:
    """Return a TOC-safe title without visual badges or inline-only tokens."""

    cleaned = re.sub(r"\{\{\s*(?:badge|evidence)\s*:[^}]+?\s*\}\}", "", title, flags=re.I)
    return " ".join(cleaned.split())


def is_executive_summary(title: str) -> bool:
    return toc_title(title).lower() == "executive summary"


def wrap_document(headings: list[tuple[int, str, str]], body: str) -> str:
    css = load_css(TEMPLATE, PDF_PROFILE)
    pdf_href = os.environ.get("REPORT_PDF_HREF", "").strip()
    pdf_landscape_href = os.environ.get("REPORT_PDF_LANDSCAPE_HREF", "").strip()
    pdf_link = ""
    pdf_links = []
    if pdf_href:
        pdf_links.append(
            f'<a class="toc-pdf-link" href="{html.escape(pdf_href)}" '
            'aria-label="Open A4 PDF version" title="Open A4 PDF version">A4</a>'
        )
    if pdf_landscape_href:
        pdf_links.append(
            f'<a class="toc-pdf-link" href="{html.escape(pdf_landscape_href)}" '
            'aria-label="Open landscape PDF version" title="Open landscape PDF version">16:9</a>'
        )
    if pdf_links:
        pdf_link = f'<span class="toc-pdf-actions">{"".join(pdf_links)}</span>'
    toc_items = []
    chapter = 0
    section = 0
    for level, title, anchor in headings:
        clean_title = toc_title(title)
        label = clean_title
        if level == 2 and not is_executive_summary(title):
            chapter += 1
            section = 0
            label = f"{chapter}. {clean_title}"
        elif level == 3 and chapter:
            section += 1
            label = f"{chapter}.{section} {clean_title}"
        indent = f' style="margin-left:{max(level - 1, 0)}rem"'
        toc_items.append(f'<li><a href="#{anchor}"{indent}>{inline_markup(label)}</a></li>')
    active_toc_script = """
<script>
(() => {
  const links = Array.from(document.querySelectorAll('.sticky-toc a[href^="#"]'));
  const headings = links.map((link) => document.getElementById(link.getAttribute('href').slice(1))).filter(Boolean);
  const setActive = (id) => {
    links.forEach((link) => link.setAttribute('aria-current', link.getAttribute('href') === `#${id}` ? 'true' : 'false'));
  };
  if (!('IntersectionObserver' in window) || headings.length === 0) {
    if (headings[0]) setActive(headings[0].id);
    return;
  }
  const observer = new IntersectionObserver((entries) => {
    const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (visible) setActive(visible.target.id);
  }, { rootMargin: '-20% 0px -65% 0px', threshold: [0, 1] });
  headings.forEach((heading) => observer.observe(heading));
  setActive(headings[0].id);
})();
</script>
<script>
(() => {
  document.querySelectorAll('.code-copy').forEach((button) => {
    button.addEventListener('click', async () => {
      const code = button.closest('.code-block-wrap')?.querySelector('code')?.innerText || '';
      const original = button.dataset.originalLabel || button.textContent || '⧉';
      button.dataset.originalLabel = original;
      const showCopied = () => {
        button.textContent = '✓';
        button.classList.add('is-copied');
        button.setAttribute('aria-label', 'Copied');
        setTimeout(() => {
          button.textContent = original;
          button.classList.remove('is-copied');
          button.setAttribute('aria-label', 'Copy code');
        }, 1200);
      };
      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(code);
        } else {
          const textArea = document.createElement('textarea');
          textArea.value = code;
          textArea.setAttribute('readonly', '');
          textArea.style.position = 'fixed';
          textArea.style.left = '-9999px';
          document.body.appendChild(textArea);
          textArea.select();
          document.execCommand('copy');
          textArea.remove();
        }
        showCopied();
      } catch (_) {
        button.textContent = 'Copy';
      }
    });
  });
})();
</script>
""".strip()
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Report</title>
<style>{css}</style>
</head>
<body class="report-body report-theme-{html.escape(THEME)} report-pdf-profile-{html.escape(PDF_PROFILE)} report-template-{html.escape(TEMPLATE)}">
<div class="report-shell">
<nav class="sticky-toc" aria-label="Report table of contents">
<div class="sticky-toc-header"><h2>Contents</h2>{pdf_link}</div>
<ol>
{chr(10).join(toc_items)}
</ol>
</nav>
<main class="report-content report-main">
{body}
</main>
</div>
<footer class="report-footer">© 2025-2026 Marcus Quinn. Licensed under MIT.</footer>
{active_toc_script}
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


def handle_static_mode() -> bool:
    if MODE == "print-css":
        print(load_css(TEMPLATE, PDF_PROFILE))
        return True
    if MODE == "list-templates":
        print("\n".join(BUILTIN_TEMPLATES))
        return True
    if MODE == "list-dark-templates":
        print("\n".join(dark_style_names()))
        return True
    if MODE == "sample-json":
        print(sample_json())
        return True
    return False


def handle_text_mode(text: str) -> None:
    if MODE == "action-prompts":
        sys.stdout.write(render_action_prompt_markdown(text))
        return
    if MODE == "validate":
        stripped = text.lstrip()
        if stripped.startswith(("{", "[")):
            validate_json_badges(json.loads(text))
        else:
            validate_markdown_badges(text)
        return
    stripped = text.lstrip()
    headings, body = render_json(text) if stripped.startswith(("{", "[")) else render_markdown(text)
    sys.stdout.write(wrap_document(headings, body))


def main() -> int:
    if handle_static_mode():
        return 0
    handle_text_mode(read_input(INPUT))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)
