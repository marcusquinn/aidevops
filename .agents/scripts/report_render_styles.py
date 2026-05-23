#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Load report renderer style presets from DESIGN.md brand files."""

from __future__ import annotations

from pathlib import Path

STYLE_SLUGS = (
    "axel",
    "arxiv",
    "wikipedia",
    "medium",
    "ghost",
    "ulysses",
    "ia",
    "docuseal",
    "times",
    "consumer",
    "tavily",
    "supermemory",
    "savvy",
    "exsqueezeme",
    "terminalshop",
    "scalefusion",
    "zeroheight",
    "superx",
    "wpcodebox",
    "outrank",
    "lottiefiles",
    "knob",
    "postedapp",
    "serper",
    "indexsy",
    "lifee",
    "bento",
    "ibm",
    "apple",
    "cabinet",
    "heron",
    "usgraphics",
)

DEFAULT_TOKENS = {
    "background": "#f8f6f1",
    "surface": "#ffffff",
    "on-surface": "#111827",
    "muted": "#4b5563",
    "outline": "#d1d5db",
    "primary": "#2563eb",
    "primary-container": "#dbeafe",
    "headline-display.fontFamily": 'Inter, system-ui, -apple-system, "Segoe UI", sans-serif',
    "body-md.fontFamily": 'Inter, system-ui, -apple-system, "Segoe UI", sans-serif',
    "code-md.fontFamily": '"IBM Plex Mono", "SFMono-Regular", Consolas, monospace',
    "rounded.lg": "12px",
}


def _brand_root() -> Path:
    return Path(__file__).resolve().parents[1] / "tools" / "design" / "library" / "brands"


def _front_matter(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    start = -1
    for index, line in enumerate(lines[:8]):
        if line.strip() == "---":
            start = index
            break
    if start == -1:
        return []
    for index, line in enumerate(lines[start + 1 :], start=start + 1):
        if line.strip() == "---":
            return lines[start + 1 : index]
    return []


def _clean(value: str) -> str:
    return value.strip().strip('"').strip("'")


def _parse_tokens(lines: list[str]) -> dict[str, str]:
    tokens: dict[str, str] = {}
    section = ""
    nested = ""
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if indent == 0 and stripped.endswith(":"):
            section = stripped[:-1]
            nested = ""
            continue
        if section == "colors" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            tokens[key.strip()] = _clean(value)
            continue
        if section == "rounded" and indent == 2 and ":" in stripped:
            key, value = stripped.split(":", 1)
            tokens[f"rounded.{key.strip()}"] = _clean(value)
            continue
        if section == "typography" and indent == 2 and stripped.endswith(":"):
            nested = stripped[:-1]
            continue
        if section == "typography" and nested and indent == 4 and ":" in stripped:
            key, value = stripped.split(":", 1)
            tokens[f"{nested}.{key.strip()}"] = _clean(value)
    return tokens


def _tokens_for(name: str) -> dict[str, str]:
    path = _brand_root() / name / "DESIGN.md"
    tokens = dict(DEFAULT_TOKENS)
    if path.exists():
        tokens.update(_parse_tokens(_front_matter(path)))
    return tokens


def style_names() -> tuple[str, ...]:
    """Return supported DESIGN.md-backed report style identifiers."""

    return tuple(sorted(STYLE_SLUGS))


def style_css(name: str) -> str:
    """Return renderer CSS compiled from a brand DESIGN.md file."""

    tokens = _tokens_for(name)
    return f"""
:root {{ color-scheme: light dark; --report-paper: {tokens['background']}; --report-surface: {tokens['surface']}; --report-ink: {tokens['on-surface']}; --report-muted: {tokens['muted']}; --report-line: {tokens['outline']}; --report-panel: {tokens['surface']}; --report-blue: {tokens['primary']}; --report-accent-soft: {tokens['primary-container']}; --report-radius: {tokens['rounded.lg']}; --report-heading: {tokens['headline-display.fontFamily']}; --report-body: {tokens['body-md.fontFamily']}; --report-mono: {tokens['code-md.fontFamily']}; }}
body.report-body {{ margin: 0; background: var(--report-paper); color: var(--report-ink); font: 16px/1.62 var(--report-body); }}
.report-shell {{ display: grid; grid-template-columns: minmax(0, 1fr) minmax(14rem, 19rem); gap: 2rem; max-width: 1180px; margin: 0 auto; padding: 2rem; }}
.report-content, .report-main {{ min-width: 0; }}
h1,h2,h3 {{ color: var(--report-ink); font-family: var(--report-heading); line-height: 1.12; letter-spacing: -0.02em; break-after: avoid; }}
h1 {{ font-size: clamp(2.6rem, 7vw, 4.8rem); }}
.sticky-toc {{ position: sticky; top: 1rem; align-self: start; max-height: calc(100vh - 2rem); overflow: auto; border: 1px solid var(--report-line); border-radius: var(--report-radius); padding: 1rem; background: var(--report-panel); box-shadow: 0 10px 32px rgba(15, 23, 42, .08); }}
.sticky-toc a {{ display: block; color: var(--report-muted); text-decoration: none; margin: .35rem 0; border-left: 3px solid transparent; padding-left: .5rem; }}
.sticky-toc a:hover, .sticky-toc a:focus-visible {{ border-left-color: var(--report-blue); color: var(--report-ink); }}
.badge {{ display: inline-block; border-radius: 999px; padding: .15rem .55rem; font-size: .78rem; font-weight: 800; border: 1px solid var(--report-line); background: var(--report-accent-soft); color: var(--report-ink); }}
.badge-verified {{ background: #dcfce7; color: #166534; }} .badge-partial {{ background: #fef9c3; color: #854d0e; }} .badge-inferred {{ background: #dbeafe; color: #1e40af; }} .badge-missing {{ background: #fee2e2; color: #991b1b; }}
.source-card {{ border: 1px solid var(--report-line); border-left: 5px solid var(--report-blue); border-radius: var(--report-radius); padding: .9rem 1rem; margin: .8rem 0; background: var(--report-surface); }}
table {{ table-layout: fixed; border-collapse: collapse; width: 100%; margin: 1rem 0; overflow-wrap: anywhere; background: var(--report-surface); }}
th, td {{ border: 1px solid var(--report-line); padding: .55rem; text-align: left; vertical-align: top; }}
code, pre {{ font-family: var(--report-mono); }}
@media (max-width: 860px) {{ .report-shell {{ display: block; padding: 1rem; }} .sticky-toc {{ position: static; margin-bottom: 1rem; }} }}
@media (prefers-color-scheme: dark) {{ :root {{ --report-paper: #0b1020; --report-surface: #111827; --report-ink: #f9fafb; --report-muted: #cbd5e1; --report-line: #334155; --report-panel: #111827; }} .sticky-toc {{ box-shadow: none; }} }}
""".strip()
