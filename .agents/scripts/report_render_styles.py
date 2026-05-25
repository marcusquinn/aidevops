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
    "mellowyellow",
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

TOKEN_SECTION_PREFIXES = {
    "colors": "",
    "rounded": "rounded.",
    "typography": "",
}

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
    for index, line in enumerate(lines[:100]):
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


def _hex_to_rgb(value: str) -> tuple[float, float, float] | None:
    raw = value.strip()
    if not raw.startswith("#"):
        return None
    raw = raw[1:]
    if len(raw) == 3:
        raw = "".join(ch * 2 for ch in raw)
    if len(raw) != 6:
        return None
    try:
        return tuple(int(raw[index : index + 2], 16) / 255 for index in (0, 2, 4))  # type: ignore[return-value]
    except ValueError:
        return None


def _rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{round(max(0, min(1, channel)) * 255):02X}" for channel in rgb)


def _relative_luminance(rgb: tuple[float, float, float]) -> float:
    def channel(value: float) -> float:
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(value) for value in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast_ratio(fg: tuple[float, float, float], bg: tuple[float, float, float]) -> float:
    light = max(_relative_luminance(fg), _relative_luminance(bg))
    dark = min(_relative_luminance(fg), _relative_luminance(bg))
    return (light + 0.05) / (dark + 0.05)


def _mix(rgb: tuple[float, float, float], target: tuple[float, float, float], amount: float) -> tuple[float, float, float]:
    return tuple(channel + (target[index] - channel) * amount for index, channel in enumerate(rgb))  # type: ignore[return-value]


def _ensure_contrast(fg_value: str, bg_value: str, minimum: float) -> str:
    fg = _hex_to_rgb(fg_value)
    bg = _hex_to_rgb(bg_value)
    if fg is None or bg is None or _contrast_ratio(fg, bg) >= minimum:
        return fg_value
    target = (1.0, 1.0, 1.0) if _relative_luminance(bg) < 0.45 else (0.0, 0.0, 0.0)
    adjusted = fg
    for step in range(1, 21):
        adjusted = _mix(fg, target, step / 20)
        if _contrast_ratio(adjusted, bg) >= minimum:
            return _rgb_to_hex(adjusted)
    return _rgb_to_hex(adjusted)


def _accessible_tokens(tokens: dict[str, str]) -> dict[str, str]:
    adjusted = dict(tokens)
    surface = adjusted.get("surface", adjusted["background"])
    adjusted["on-surface"] = _ensure_contrast(adjusted["on-surface"], surface, 4.5)
    adjusted["muted"] = _ensure_contrast(adjusted["muted"], surface, 4.5)
    adjusted["primary"] = _ensure_contrast(adjusted["primary"], surface, 4.5)
    adjusted["outline"] = _ensure_contrast(adjusted["outline"], surface, 2.0)
    if "surface-dark" in adjusted:
        dark_surface = adjusted.get("surface-dark", adjusted.get("background-dark", surface))
        adjusted["on-surface-dark"] = _ensure_contrast(adjusted.get("on-surface-dark", "#ffffff"), dark_surface, 4.5)
        adjusted["muted-dark"] = _ensure_contrast(adjusted.get("muted-dark", "#cbd5e1"), dark_surface, 4.5)
        adjusted["primary-dark"] = _ensure_contrast(adjusted.get("primary-dark", adjusted["primary"]), dark_surface, 4.5)
        adjusted["outline-dark"] = _ensure_contrast(adjusted.get("outline-dark", "#334155"), dark_surface, 2.0)
    return adjusted


def _parse_mapping(line: str, prefix: str = "") -> tuple[str, str] | None:
    if ":" not in line:
        return None
    key, value = line.split(":", 1)
    return f"{prefix}{key.strip()}", _clean(value)


def _indent_width(line: str) -> int:
    width = 0
    for char in line:
        if char == " ":
            width += 1
            continue
        if char == "\t":
            width += 4
            continue
        break
    return width


def _parse_nested_mapping(lines: list[str]) -> dict[str, object]:
    root: dict[str, object] = {}
    stack: list[tuple[int, dict[str, object]]] = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        parsed = _parse_mapping(stripped)
        if parsed is None:
            continue
        key, value = parsed
        indent = _indent_width(line)
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack else root
        if stripped.endswith(":") and value == "":
            child: dict[str, object] = {}
            parent[key] = child
            stack.append((indent, child))
            continue
        parent[key] = value
    return root


def _flatten_token_mapping(value: object, prefix: str = "") -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    flattened: dict[str, str] = {}
    for key, item in value.items():
        token_key = f"{prefix}{key}"
        if isinstance(item, dict):
            flattened.update(_flatten_token_mapping(item, f"{token_key}."))
            continue
        flattened[token_key] = str(item)
    return flattened


def _parse_tokens(lines: list[str]) -> dict[str, str]:
    tokens: dict[str, str] = {}
    document = _parse_nested_mapping(lines)
    for section, prefix in TOKEN_SECTION_PREFIXES.items():
        tokens.update(_flatten_token_mapping(document.get(section), prefix))
    return tokens


def _tokens_for(name: str) -> dict[str, str]:
    path = _brand_root() / name / "DESIGN.md"
    tokens = dict(DEFAULT_TOKENS)
    if path.exists():
        tokens.update(_parse_tokens(_front_matter(path)))
    return _accessible_tokens(tokens)


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
    light_companion = ""
    background_rgb = _hex_to_rgb(tokens.get("background", "#ffffff"))
    if background_rgb is not None and _relative_luminance(background_rgb) < 0.2:
        light_primary = _ensure_contrast(tokens["primary"], "#FFFFFF", 4.5)
        light_companion = f"""
body.report-theme-light {{
  --report-paper: #F8FAFC;
  --report-paper-raised: #FFFFFF;
  --report-panel: #FFFFFF;
  --report-surface: #FFFFFF;
  --report-ink: #111827;
  --report-ink-muted: #4B5563;
  --report-ink-soft: #4B5563;
  --report-rule: #D1D5DB;
  --report-rule-strong: {light_primary};
  --report-blue: {light_primary};
  --report-action-bg: {light_primary};
  --report-action-ink: #FFFFFF;
  --report-info-bg: #FFFFFF;
  --report-impact-bg: #FFFFFF;
  --report-evidence-bg: #FFFFFF;
  --report-myth-bg: #FFFFFF;
  --report-good-bg: #FFFFFF;
  --report-bad-bg: #FFFFFF;
  --report-code-bg: #F8FAFC;
  --report-code-bg-2: #FFFFFF;
  --report-code-ink: #111827;
  --report-code-accent: {light_primary};
}}
""".strip()
    return f"""
{dark_vars}
{light_companion}
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


TEMPLATE_SPECIFIC_CSS = {
    "medium": """
.report-template-medium .report-main { max-width: none; }
.report-template-medium .report-shell { max-width: var(--report-page-max); }
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
""".strip(),
    "lottiefiles": """
.report-template-lottiefiles h1,
.report-template-lottiefiles h2,
.report-template-lottiefiles h3,
.report-template-lottiefiles .stat-card strong { font-family: "DM Sans", Inter, system-ui, sans-serif; }
.report-template-lottiefiles .report-cover,
.report-template-lottiefiles .stat-card,
.report-template-lottiefiles .tactic-card,
.report-template-lottiefiles .source-card { border-radius: 20px; }
.report-template-lottiefiles .action-line { box-shadow: 0 20px 48px rgba(1, 157, 145, 0.18); }
""".strip(),
    "times": """
.report-template-times { background-image: linear-gradient(rgba(0, 0, 0, 0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(0, 0, 0, 0.025) 1px, transparent 1px); background-size: 18rem 18rem; }
.report-template-times .report-cover { text-align: center; border-width: 2px 0; border-color: #000000; box-shadow: none; background: rgba(255, 253, 248, 0.7); }
.report-template-times .report-cover h1 { font-size: clamp(3rem, 7vw, 5.5rem); line-height: 0.98; }
.report-template-times .report-main h1,
.report-template-times .report-main h2,
.report-template-times .report-main h3 { text-transform: uppercase; }
.report-template-times .report-main p { font-family: Georgia, "Times New Roman", serif; }
.report-template-times .report-meta,
.report-template-times .sticky-toc,
.report-template-times .badge,
.report-template-times .toc-pdf-link,
.report-template-times code,
.report-template-times pre,
.report-template-times .facts-table td:last-child,
.report-template-times .facts-table th { font-family: Menlo, Monaco, "Courier New", monospace; }
.report-template-times .report-cover,
.report-template-times .chapter-hero,
.report-template-times .tactic-card,
.report-template-times .source-card,
.report-template-times .priority-group,
.report-template-times .stat-card,
.report-template-times .facts-table-wrap { border-color: #000000; border-radius: 0; box-shadow: none; }
.report-template-times .chapter-hero { border-width: 2px 0; text-align: center; background: #FFFDF8; }
.report-template-times .toc-pdf-link,
.report-template-times .action-line strong { background: #000000; color: #ffffff; border-color: #000000; }
.report-template-times .sticky-toc ol a:hover,
.report-template-times .sticky-toc ol a:focus-visible,
.report-template-times .sticky-toc ol a[aria-current="true"] { color: #008138; border-left-color: #008138; }
.report-template-times .facts-table th,
.report-template-times .facts-table td { border-bottom-style: dotted; }
.report-template-times .code-block-wrap { border-color: #000000; border-radius: 0; }
""".strip(),
    "indexsy": """
.report-template-indexsy .report-shell { max-width: 1320px; }
.report-template-indexsy .report-cover,
.report-template-indexsy .chapter-hero { text-align: center; background: transparent; border-color: transparent; box-shadow: none; }
.report-template-indexsy .report-cover h1,
.report-template-indexsy h1 { font-size: clamp(2.5rem, 5vw, 3.75rem); font-weight: 500; letter-spacing: -0.045em; }
.report-template-indexsy h2 { font-size: clamp(1.75rem, 3vw, 2.35rem); font-weight: 500; letter-spacing: -0.035em; }
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
body.report-theme-light.report-template-indexsy .heading-number,
body.report-theme-light.report-template-indexsy ol li::marker { color: #4721fb; }
body.report-theme-light.report-template-indexsy .sticky-toc,
body.report-theme-light.report-template-indexsy .tactic-card,
body.report-theme-light.report-template-indexsy .source-card,
body.report-theme-light.report-template-indexsy .priority-group,
body.report-theme-light.report-template-indexsy .stat-card { box-shadow: 0 18px 42px rgba(17, 24, 39, 0.12); }
body.report-theme-light.report-template-indexsy .badge-verified,
body.report-theme-light.report-template-indexsy .badge-partial,
body.report-theme-light.report-template-indexsy .badge-inferred,
body.report-theme-light.report-template-indexsy .badge-missing { border-color: var(--report-rule); }
""".strip(),
    "docuseal": """
.report-template-docuseal .report-cover { text-align: center; }
.report-template-docuseal .action-line strong,
.report-template-docuseal .toc-pdf-link { background: #181818; color: #ffffff; border-color: #181818; }
.report-template-docuseal .stat-card,
.report-template-docuseal .chapter-hero { background: #FFE2C2; }
""".strip(),
    "exsqueezeme": """
.report-template-exsqueezeme .report-cover,
.report-template-exsqueezeme .chapter-hero { background: radial-gradient(circle at 20% 10%, rgba(255, 95, 31, 0.18), transparent 28%), var(--report-panel); text-align: center; }
.report-template-exsqueezeme h1,
.report-template-exsqueezeme h2,
.report-template-exsqueezeme h3 { text-transform: uppercase; }
.report-template-exsqueezeme .toc-pdf-link,
.report-template-exsqueezeme .action-line strong { background: #FF5F1F; color: #0A0A0A; border-color: #ffffff; box-shadow: 5px 5px 0 #ffffff; }
.report-template-exsqueezeme .report-cover,
.report-template-exsqueezeme .tactic-card,
.report-template-exsqueezeme .source-card,
.report-template-exsqueezeme .facts-table-wrap { box-shadow: 6px 6px 0 #ffffff; }
body.report-theme-light.report-template-exsqueezeme .toc-pdf-link,
body.report-theme-light.report-template-exsqueezeme .action-line strong { border-color: #0A0A0A; box-shadow: 5px 5px 0 rgba(10, 10, 10, 0.16); }
body.report-theme-light.report-template-exsqueezeme .report-cover,
body.report-theme-light.report-template-exsqueezeme .tactic-card,
body.report-theme-light.report-template-exsqueezeme .source-card,
body.report-theme-light.report-template-exsqueezeme .facts-table-wrap { box-shadow: 6px 6px 0 rgba(10, 10, 10, 0.12); }
""".strip(),
    "mellowyellow": """
.report-template-mellowyellow .report-cover,
.report-template-mellowyellow .chapter-hero,
.report-template-mellowyellow .stat-card { background: var(--report-paper-raised); }
""".strip(),
    "superx": """
.report-template-superx .report-cover,
.report-template-superx .chapter-hero { background: radial-gradient(circle at 70% 10%, rgba(252, 138, 101, 0.28), transparent 38%), var(--report-panel); }
.report-template-superx .action-line,
.report-template-superx .toc-pdf-link { box-shadow: 0 0 26px rgba(252, 138, 101, 0.18); }
.report-template-superx .stat-card strong { color: #ffffff; }
body.report-theme-light.report-template-superx .stat-card strong { color: var(--report-ink); }
""".strip(),
    "terminalshop": """
.report-template-terminalshop .report-cover,
.report-template-terminalshop .chapter-hero,
.report-template-terminalshop .tactic-card,
.report-template-terminalshop .source-card,
.report-template-terminalshop .info-panel,
.report-template-terminalshop .impact-panel,
.report-template-terminalshop .evidence-panel,
.report-template-terminalshop .action-panel,
.report-template-terminalshop .good-row,
.report-template-terminalshop .bad-row,
.report-template-terminalshop .myth-callout { background: #111315; color: #ffffff; }
.report-template-terminalshop .toc-pdf-link,
.report-template-terminalshop .action-line strong { border-radius: 0; }
.report-template-terminalshop a { color: #59C2FF; }
body.report-theme-light.report-template-terminalshop .report-cover,
body.report-theme-light.report-template-terminalshop .chapter-hero,
body.report-theme-light.report-template-terminalshop .tactic-card,
body.report-theme-light.report-template-terminalshop .source-card,
body.report-theme-light.report-template-terminalshop .info-panel,
body.report-theme-light.report-template-terminalshop .impact-panel,
body.report-theme-light.report-template-terminalshop .evidence-panel,
body.report-theme-light.report-template-terminalshop .action-panel,
body.report-theme-light.report-template-terminalshop .good-row,
body.report-theme-light.report-template-terminalshop .bad-row,
body.report-theme-light.report-template-terminalshop .myth-callout { background: var(--report-surface); color: var(--report-ink); }
body.report-theme-light.report-template-terminalshop a { color: var(--report-blue); }
""".strip(),
    "ulysses": """
.report-template-ulysses .report-cover { background: #ffffff; box-shadow: none; }
.report-template-ulysses .chapter-hero { background: #333333; color: #ffffff; }
.report-template-ulysses .chapter-hero * { color: inherit; }
.report-template-ulysses .heading-number,
.report-template-ulysses ol li::marker { color: #F7C600; }
""".strip(),
    "usgraphics": """
.report-template-usgraphics .report-cover,
.report-template-usgraphics .chapter-hero,
.report-template-usgraphics .tactic-card,
.report-template-usgraphics .source-card,
.report-template-usgraphics .facts-table-wrap { box-shadow: none; border-radius: 0; }
.report-template-usgraphics .toc-pdf-link,
.report-template-usgraphics .badge,
.report-template-usgraphics .appendix-links a,
.report-template-usgraphics .anchor-links a { border-radius: 0; }
.report-template-usgraphics h1,
.report-template-usgraphics h2,
.report-template-usgraphics h3 { text-transform: none; }
.report-template-usgraphics a { text-decoration: underline; text-underline-offset: 0.12em; }
""".strip(),
}


def _template_specific_css(name: str) -> str:
    return TEMPLATE_SPECIFIC_CSS.get(name, "")


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
  --report-badge-radius: calc({tokens['rounded.lg']} * 0.45);
  --report-code-bg: {tokens.get('code-background', tokens['surface'])};
  --report-code-ink: {tokens.get('code-on-background', tokens['on-surface'])};
  --report-code-accent: {tokens.get('code-accent', tokens['primary'])};
  --report-info-bg: {tokens.get('info-background', tokens['surface'])};
  --report-impact-bg: {tokens.get('impact-background', tokens['surface'])};
  --report-evidence-bg: {tokens.get('evidence-background', tokens['surface'])};
  --report-myth-bg: {tokens.get('myth-background', tokens['surface'])};
  --report-good-bg: {tokens.get('good-background', tokens['surface'])};
  --report-bad-bg: {tokens.get('bad-background', tokens['surface'])};
}}
body.report-body {{ font-family: var(--report-font-body); font-size: clamp(1rem, 0.94rem + 0.18vw, 1.0625rem); line-height: 1.62; }}
h1, h2, h3 {{ font-family: var(--report-font-heading); font-weight: var(--report-heading-weight); letter-spacing: var(--report-heading-tracking); }}
h1 {{ font-size: clamp(2.25rem, 5vw, 3.5rem); line-height: 1.12; }}
h2 {{ font-size: clamp(1.6rem, 3vw, 2.25rem); line-height: 1.16; }}
h3 {{ font-size: clamp(1.15rem, 1.5vw, 1.35rem); line-height: 1.24; }}
.source-card, .tactic-card, .priority-group {{ border-color: var(--report-rule); }}
.sticky-toc ol a:hover, .sticky-toc ol a:focus-visible, .sticky-toc ol a[aria-current="true"] {{ border-left-color: var(--report-blue); }}
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
