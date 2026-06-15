#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate brand guideline Markdown from a DESIGN.md file."""

from __future__ import annotations

from pathlib import Path
import re
import sys


def _split_design(text: str) -> tuple[str, str]:
    if not text.startswith("---"):
        return "", text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return "", text
    return parts[1], parts[2]


def _scalar(front: str, name: str, default: str = "") -> str:
    match = re.search(rf"(?m)^{re.escape(name)}:\s*(.+?)\s*$", front)
    if not match:
        return default
    return match.group(1).strip().strip("\"'")


def _section_lines(front: str, name: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    capture = False
    for line in front.splitlines():
        if re.match(rf"^{re.escape(name)}:\s*$", line):
            capture = True
            continue
        if capture and re.match(r"^[A-Za-z0-9_-]+:\s*", line):
            break
        if not capture:
            continue
        match = re.match(r"^\s{2}([A-Za-z0-9_.-]+):\s*(.+?)\s*$", line)
        if match and not match.group(2).lstrip().startswith("#"):
            out.append((match.group(1), match.group(2).strip().strip("\"'")))
    return out


def _prose_section(body: str, title: str) -> str:
    pattern = re.compile(rf"(?ms)^##\s+\d*\.?\s*{re.escape(title)}\s*\n(.*?)(?=^##\s+|\Z)")
    match = pattern.search(body)
    if not match:
        return ""
    content = re.sub(r"<!--.*?-->", "", match.group(1), flags=re.S).strip()
    return content[:1200]


def _append_cover(lines: list[str], description: str, design_path: Path) -> None:
    lines.extend(
        [
            "::: report-cover",
            f"**{description}**",
            "",
            "Generated from the project-root `DESIGN.md` so implementation agents, designers, and reviewers share one canonical visual source of truth.",
            ":::",
            "",
            "::: manifest-card",
            "",
            "### Production manifest",
            "",
            f"- **Design source:** `{design_path.name}`",
            "- **Canonical use:** UI implementation, screenshots, report styling, and brand handoff",
            "- **Verification:** lint `DESIGN.md`, regenerate this guide, then review HTML/PDF exports",
            "- **Change rule:** update `DESIGN.md` first; regenerate generated outputs rather than editing them by hand",
            ":::",
            "",
        ]
    )


def _append_colours(lines: list[str], colors: list[tuple[str, str]]) -> None:
    lines.extend(["## Colour roles", ""])
    if not colors:
        lines.extend(["No colour tokens were found in the YAML front matter.", ""])
        return
    lines.append("::: brand-swatch-grid")
    for key, value in colors:
        accent = key.replace("on-", "").replace("_", "-")
        lines.extend([f"::: swatch-card accent={accent}", "", f"### {key}", "", f"`{value}`", ":::"])
    lines.extend([":::", ""])


def _append_token_table(lines: list[str], spacing: list[tuple[str, str]], rounded: list[tuple[str, str]]) -> None:
    spacing_values = ", ".join(f"`{key}` {value}" for key, value in spacing) or "Populate `spacing:` tokens"
    rounded_values = ", ".join(f"`{key}` {value}" for key, value in rounded) or "Populate `rounded:` tokens"
    lines.extend(
        [
            "## Typography and layout tokens",
            "",
            "::: facts-table-wrap",
            "",
            "| Token group | Values | Usage |",
            "|---|---|---|",
            f"| Spacing | {spacing_values} | Layout rhythm, gutters, section spacing |",
            f"| Rounded | {rounded_values} | Shape language for buttons, cards, forms |",
            ":::",
            "",
        ]
    )


def render_markdown(design_path: Path) -> str:
    text = design_path.read_text(encoding="utf-8")
    front, body = _split_design(text)
    name = _scalar(front, "name", design_path.parent.name)
    description = _scalar(front, "description", f"Brand guidelines generated from {design_path.name}.")
    colors = _section_lines(front, "colors")
    spacing = _section_lines(front, "spacing")
    rounded = _section_lines(front, "rounded")
    overview = _prose_section(body, "Overview")
    dos = _prose_section(body, "Do's and Don'ts") or _prose_section(body, "Dos and Don'ts")
    agent = _prose_section(body, "Agent Prompt Guide")

    lines = [f"# {name} Brand Guidelines", ""]
    _append_cover(lines, description, design_path)
    lines.extend(["## Brand overview", "", overview or "Populate the Overview section in `DESIGN.md` with the product mood, density, atmosphere, and key characteristics.", ""])
    _append_colours(lines, colors)
    _append_token_table(lines, spacing, rounded)
    lines.extend(
        [
            "## Component and state guidance",
            "",
            "Use the `components:` YAML tokens in `DESIGN.md` for exact button, input, card, badge, and navigation styling. Add missing component states before implementation when hover, focus, disabled, error, loading, or selected states are not explicit.",
            "",
            "## Do's and don'ts",
            "",
            dos or "Populate the Do's and Don'ts section in `DESIGN.md` with concrete visual rules, anti-patterns, accessibility constraints, and content tone guidance.",
            "",
            "## Agent handoff",
            "",
            agent or "Implementation agents must read `DESIGN.md` before UI changes, preserve token names where practical, and regenerate this guide after brand-significant edits.",
            "",
            "## Verification checklist",
            "",
            "- [ ] `npx @google/design.md lint DESIGN.md` exits with zero errors; warnings reviewed",
            "- [ ] `aidevops design guidelines . --pdf` regenerates Markdown, HTML, and PDFs",
            "- [ ] Browser review confirms colour contrast, typography hierarchy, component states, and print/PDF layout",
            "- [ ] Generated files contain no private URLs, credentials, raw transcripts, or unapproved client identifiers",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: design_guidelines_render.py DESIGN.md OUTPUT.md", file=sys.stderr)
        return 2
    design_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    output_path.write_text(render_markdown(design_path), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
