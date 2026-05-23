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
    "headline-display.fontSize": "64px",
    "headline-display.fontWeight": "650",
    "headline-display.lineHeight": "1.05",
    "headline-display.letterSpacing": "-0.03em",
    "body-md.fontFamily": 'Inter, system-ui, -apple-system, "Segoe UI", sans-serif',
    "body-md.fontSize": "16px",
    "body-md.lineHeight": "1.62",
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


def _dark_variable_css(tokens: dict[str, str], selector: str) -> str:
    return f"""
  {selector} {{
    --report-paper: {tokens['background-dark']};
    --report-paper-raised: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-panel: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-surface: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-ink: {tokens.get('on-surface-dark', '#ffffff')};
    --report-ink-muted: {tokens.get('muted-dark', '#cbd5e1')};
    --report-ink-soft: {tokens.get('muted-dark', '#cbd5e1')};
    --report-rule: {tokens.get('outline-dark', '#334155')};
    --report-rule-strong: {tokens.get('outline-dark', '#334155')};
    --report-blue: {tokens.get('primary-dark', tokens['primary'])};
    --report-action-bg: {tokens.get('primary-dark', tokens['primary'])};
    --report-action-ink: {tokens.get('background-dark', '#0b1020')};
    --report-info-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-impact-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-evidence-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-myth-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-good-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-bad-bg: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-code-bg: {tokens.get('background-dark', '#0b1020')};
    --report-code-bg-2: {tokens.get('surface-dark', tokens['background-dark'])};
    --report-code-ink: {tokens.get('on-surface-dark', '#ffffff')};
    --report-code-accent: {tokens.get('primary-dark', tokens['primary'])};
  }}
""".strip()


def _optional_dark_tokens(tokens: dict[str, str]) -> str:
    if "background-dark" not in tokens:
        return ""
    dark_vars = _dark_variable_css(tokens, "body.report-theme-dark")
    auto_dark_vars = _dark_variable_css(tokens, "body.report-theme-auto")
    return f"""
{dark_vars}
body.report-theme-dark .badge-verified,
body.report-theme-dark .badge-partial,
body.report-theme-dark .badge-inferred,
body.report-theme-dark .badge-missing {{ border-color: var(--report-rule); }}
body.report-theme-dark .sticky-toc {{ box-shadow: none; }}
@media (prefers-color-scheme: dark) {{
  {auto_dark_vars}
  body.report-theme-auto .badge-verified,
  body.report-theme-auto .badge-partial,
  body.report-theme-auto .badge-inferred,
  body.report-theme-auto .badge-missing {{ border-color: var(--report-rule); }}
  body.report-theme-auto .sticky-toc {{ box-shadow: none; }}
}}
""".strip()


def style_has_dark(name: str) -> bool:
    """Return whether a report style has explicit dark/inverse tokens."""

    return "background-dark" in _tokens_for(name)


def dark_style_names() -> tuple[str, ...]:
    """Return supported style identifiers with explicit dark/inverse tokens."""

    return tuple(name for name in style_names() if style_has_dark(name))


def _template_specific_css(name: str) -> str:
    if name == "medium":
        return """
.report-template-medium .report-main { max-width: 740px; }
.report-template-medium .report-shell { max-width: 1120px; }
.report-template-medium .report-cover,
.report-template-medium .tactic-card,
.report-template-medium .source-card,
.report-template-medium .priority-group,
.report-template-medium .stat-card { box-shadow: none; border-radius: 4px; }
.report-template-medium p,
.report-template-medium li,
.report-template-medium td { font-family: var(--report-font-body); font-size: 1.08rem; line-height: 1.75; }
.report-template-medium h1,
.report-template-medium h2,
.report-template-medium h3 { font-family: var(--report-font-heading); font-weight: 500; letter-spacing: -0.02em; }
""".strip()
    if name == "lottiefiles":
        return """
.report-template-lottiefiles h1,
.report-template-lottiefiles h2,
.report-template-lottiefiles h3,
.report-template-lottiefiles .stat-card strong { font-family: "DM Sans", Inter, system-ui, sans-serif; }
.report-template-lottiefiles .report-cover,
.report-template-lottiefiles .stat-card,
.report-template-lottiefiles .tactic-card,
.report-template-lottiefiles .source-card { border-radius: 20px; }
.report-template-lottiefiles .action-line { box-shadow: 0 20px 48px rgba(1, 157, 145, 0.18); }
""".strip()
    if name == "indexsy":
        return """
.report-template-indexsy .report-shell { max-width: 1320px; }
.report-template-indexsy .report-cover,
.report-template-indexsy .chapter-hero { text-align: center; background: transparent; border-color: transparent; box-shadow: none; }
.report-template-indexsy .report-cover h1,
.report-template-indexsy h1 { font-size: clamp(3.2rem, 8vw, 5.4rem); font-weight: 500; letter-spacing: -0.055em; }
.report-template-indexsy h2 { font-size: clamp(2.1rem, 4vw, 3.4rem); font-weight: 500; letter-spacing: -0.04em; }
.report-template-indexsy .heading-number,
.report-template-indexsy ol li::marker { color: #ffeb2d; }
.report-template-indexsy .toc-pdf-link,
.report-template-indexsy .action-line strong { border-color: #5270ff; color: #ffffff; background: #4721fb; }
.report-template-indexsy .sticky-toc,
.report-template-indexsy .tactic-card,
.report-template-indexsy .source-card,
.report-template-indexsy .priority-group,
.report-template-indexsy .stat-card { box-shadow: 0 24px 48px rgba(0, 0, 0, 0.28); }
.report-template-indexsy .badge-verified,
.report-template-indexsy .badge-partial,
.report-template-indexsy .badge-inferred,
.report-template-indexsy .badge-missing { border-color: rgba(255, 255, 255, 0.18); }
""".strip()
    return ""


def _theme_css(name: str, tokens: dict[str, str]) -> str:
    dark_css = _optional_dark_tokens(tokens)
    return f"""
/* DESIGN.md brand token overrides: {name} */
:root {{
  --report-font-heading: {tokens['headline-display.fontFamily']};
  --report-font-body: {tokens['body-md.fontFamily']};
  --report-font-code: {tokens['code-md.fontFamily']};
  --report-heading-size: {tokens.get('headline-display.fontSize', DEFAULT_TOKENS['headline-display.fontSize'])};
  --report-heading-weight: {tokens.get('headline-display.fontWeight', DEFAULT_TOKENS['headline-display.fontWeight'])};
  --report-heading-line: {tokens.get('headline-display.lineHeight', DEFAULT_TOKENS['headline-display.lineHeight'])};
  --report-heading-tracking: {tokens.get('headline-display.letterSpacing', DEFAULT_TOKENS['headline-display.letterSpacing'])};
  --report-body-size: {tokens.get('body-md.fontSize', DEFAULT_TOKENS['body-md.fontSize'])};
  --report-body-line: {tokens.get('body-md.lineHeight', DEFAULT_TOKENS['body-md.lineHeight'])};
  --report-paper: {tokens['background']};
  --report-paper-raised: {tokens['primary-container']};
  --report-panel: {tokens['surface']};
  --report-surface: {tokens['surface']};
  --report-ink: {tokens['on-surface']};
  --report-ink-muted: {tokens['muted']};
  --report-ink-soft: {tokens['muted']};
  --report-rule: {tokens['outline']};
  --report-rule-strong: {tokens['primary']};
  --report-blue: {tokens['primary']};
  --report-radius-lg: {tokens['rounded.lg']};
  --report-radius-xl: calc({tokens['rounded.lg']} + 0.5rem);
  --report-code-bg: {tokens.get('code-background', tokens['surface'])};
  --report-code-ink: {tokens.get('code-on-background', tokens['on-surface'])};
  --report-code-accent: {tokens.get('code-accent', tokens['primary'])};
}}
body.report-body {{ font-family: var(--report-font-body); font-size: var(--report-body-size); line-height: var(--report-body-line); }}
h1, h2, h3 {{ font-family: var(--report-font-heading); font-weight: var(--report-heading-weight); letter-spacing: var(--report-heading-tracking); }}
h1 {{ font-size: clamp(2.8rem, 8vw, var(--report-heading-size)); line-height: var(--report-heading-line); }}
.source-card, .tactic-card, .priority-group {{ border-color: var(--report-rule); }}
.sticky-toc a:hover, .sticky-toc a:focus-visible, .sticky-toc a[aria-current="true"] {{ border-left-color: var(--report-blue); }}
{dark_css}
{_template_specific_css(name)}
""".strip()


def style_names() -> tuple[str, ...]:
    """Return supported DESIGN.md-backed report style identifiers."""

    return tuple(sorted(STYLE_SLUGS))


def style_css(name: str) -> str:
    """Return renderer CSS compiled from a brand DESIGN.md file."""

    tokens = _tokens_for(name)
    return f"{_base_report_css()}\n{_theme_css(name, tokens)}"
