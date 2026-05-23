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


def _base_report_css() -> str:
    return (Path(__file__).resolve().parents[1] / "templates" / "reports" / "llm-visibility-report.css").read_text(
        encoding="utf-8"
    )


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


def _optional_dark_tokens(tokens: dict[str, str]) -> str:
    if "background-dark" not in tokens:
        return ""
    return f"""
@media (prefers-color-scheme: dark) {{
  :root {{
    --report-paper: {tokens['background-dark']};
    --report-paper-raised: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-surface: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-ink: {tokens.get('on-surface-dark', '#ffffff')};
    --report-ink-muted: {tokens.get('muted-dark', '#cbd5e1')};
    --report-ink-soft: {tokens.get('muted-dark', '#cbd5e1')};
    --report-rule: {tokens.get('outline-dark', '#334155')};
    --report-rule-strong: {tokens.get('outline-dark', '#334155')};
    --report-blue: {tokens.get('primary-dark', tokens['primary'])};
  }}
}}
""".strip()


def _theme_css(name: str, tokens: dict[str, str]) -> str:
    dark_css = _optional_dark_tokens(tokens)
    return f"""
/* DESIGN.md brand token overrides: {name} */
:root {{
  --report-font-heading: {tokens['headline-display.fontFamily']};
  --report-font-body: {tokens['body-md.fontFamily']};
  --report-font-code: {tokens['code-md.fontFamily']};
  --report-paper: {tokens['background']};
  --report-paper-raised: {tokens['primary-container']};
  --report-surface: {tokens['surface']};
  --report-ink: {tokens['on-surface']};
  --report-ink-muted: {tokens['muted']};
  --report-ink-soft: {tokens['muted']};
  --report-rule: {tokens['outline']};
  --report-rule-strong: {tokens['primary']};
  --report-blue: {tokens['primary']};
  --report-radius-lg: {tokens['rounded.lg']};
  --report-radius-xl: calc({tokens['rounded.lg']} + 0.5rem);
}}
.source-card, .tactic-card, .priority-group {{ border-color: var(--report-rule); }}
.sticky-toc a:hover, .sticky-toc a:focus-visible, .sticky-toc a[aria-current="true"] {{ border-left-color: var(--report-blue); }}
{dark_css}
""".strip()


def style_names() -> tuple[str, ...]:
    """Return supported DESIGN.md-backed report style identifiers."""

    return tuple(sorted(STYLE_SLUGS))


def style_css(name: str) -> str:
    """Return renderer CSS compiled from a brand DESIGN.md file."""

    tokens = _tokens_for(name)
    return f"{_base_report_css()}\n{_theme_css(name, tokens)}"
