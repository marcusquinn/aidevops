---
description: Render report-ready Markdown or JSON to HTML and PDF-ready previews
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Render a report-ready Markdown or JSON file:

Input: $ARGUMENTS

## Process

1. Confirm the input is a Markdown or JSON report file.
2. Run `~/.aidevops/agents/scripts/report-render-helper.sh validate <input.md|input.json>`.
3. Render HTML with `~/.aidevops/agents/scripts/report-render-helper.sh render <input.md|input.json> --output report.html`.
4. Open the HTML in a browser, review the sticky table of contents, source cards, evidence badges, and PDF links.
5. Export A4, US Letter, or slides PDFs from the generated HTML. If using Chrome/Chromium headless, pass `--no-pdf-header-footer` so browser date/title/URL/page-number chrome is not printed. Keep Markdown/JSON canonical and regenerate exports rather than editing HTML/PDF by hand.

## Usage

```bash
/report-render report.md
/report-render report.json
```

Direct helper options:

```bash
~/.aidevops/agents/scripts/report-render-helper.sh render report.md \
  --template axel \
  --theme auto \
  --pdf-profile a4 \
  --output report.html
```

## Templates and profiles

Templates:

- `basic` — lightweight default renderer style.
- `editorial-evidence` — richer report style based on the editorial evidence DESIGN.md profile.
- Original-brief named styles: run `report-render-helper.sh list-templates` for
  `axel`, `arxiv`, `wikipedia`, `medium`, `ghost`, `ulysses`, `ia`, `docuseal`,
  `times`, `consumer`, `tavily`, `supermemory`, `savvy`, `exsqueezeme`,
  `terminalshop`, `scalefusion`, `zeroheight`, `superx`, `wpcodebox`, `outrank`,
  `lottiefiles`, `knob`, `postedapp`, `serper`, `indexsy`, `lifee`, `bento`,
  `ibm`, `apple`, `cabinet`, `heron`, `usgraphics`, and `signal-agency`.

PDF profiles:

- `a4` — default A4 portrait print/PDF CSS.
- `letter` — US Letter portrait print/PDF CSS.
- `slides-16-9-1` — 16:9 landscape PDF presentation, one content column.
- `slides-16-9-2` — 16:9 landscape PDF presentation, two content columns.
- `slides-16-9-3` — 16:9 landscape PDF presentation, three content columns.

Keep one `report.html` preview per report. Do not create separate A4/Letter HTML
variants; use the selected PDF profile only when printing/exporting the PDF.

Versioned examples live under `_reports/examples/`. Open `_reports/examples/index.html`
locally to preview rendered report sets, style previews, and A4/US Letter/slides
PDF exports.

Instructional sample:

```bash
~/.aidevops/agents/scripts/report-render-helper.sh sample instructional-seo-geo > report.md
```

## Notes

- Markdown remains canonical; HTML is generated output.
- Evidence badges are limited to `verified`, `partial`, `inferred`, and `missing`.
- JSON reports use `evidence_badge` fields for the same badge values.
- `print-css --template <name> --pdf-profile <name>` exposes the matching stylesheet for custom handoff workflows.
- Use `--theme auto|light|dark` for previews. `auto` follows the viewer's colour
  scheme when the selected DESIGN.md has dark/inverse tokens; `light` and `dark`
  force one preview. `report-render-helper.sh list-dark-templates` lists styles
  with explicit dark tokens.
- Rich Markdown blocks use container fences such as `::: report-cover`, `::: stats-strip`,
  `::: tactic-card`, `::: good-bad`, `::: facts-table-wrap`, `::: example-card`,
  `::: source-card`, `::: myth-callout`, `::: accordion title="Details"`,
  `::: info-panel severity=high`, `::: action-panel`, `::: appendix-links`, and
  `::: priority-group priority=high`, closed by `:::`. Use these to exercise
  Toolbox-style report components while keeping `report.md` canonical.
- Mermaid and LaTeX are portable fallbacks: fenced `mermaid`/`latex` blocks render
  as labelled source blocks, and `{{latex:...}}` renders inline equation text.
  Use `::: bar-chart` for dependency-free report charts. Do not depend on
  external chart libraries in committed HTML unless assets are bundled locally.
