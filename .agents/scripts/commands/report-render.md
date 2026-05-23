---
description: Render report-ready Markdown or JSON to HTML for browser PDF export
agent: Document
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
4. Open the HTML in a browser, review the sticky table of contents, source cards, and evidence badges.
5. Use the browser print dialog to export or print the PDF-ready output.

## Usage

```bash
/report-render report.md
/report-render report.json
```

Direct helper options:

```bash
~/.aidevops/agents/scripts/report-render-helper.sh render report.md \
  --template axel \
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
  `ibm`, `apple`, `cabinet`, `heron`, and `usgraphics`.

PDF profiles:

- `a4` — default A4 portrait print/PDF CSS.
- `letter` — US Letter portrait print/PDF CSS.
- `slides-16-9-1` — 16:9 landscape PDF presentation, one content column.
- `slides-16-9-2` — 16:9 landscape PDF presentation, two content columns.
- `slides-16-9-3` — 16:9 landscape PDF presentation, three content columns.

Keep one `report.html` preview per report. Do not create separate A4/Letter HTML
variants; use the selected PDF profile only when printing/exporting the PDF.

Instructional sample:

```bash
~/.aidevops/agents/scripts/report-render-helper.sh sample instructional-seo-geo > report.md
```

## Notes

- Markdown remains canonical; HTML is generated output.
- Evidence badges are limited to `verified`, `partial`, `inferred`, and `missing`.
- JSON reports use `evidence_badge` fields for the same badge values.
- `print-css --template <name> --pdf-profile <name>` exposes the matching stylesheet for custom handoff workflows.
- Rich Markdown blocks use container fences such as `::: report-cover`, `::: stats-strip`,
  `::: tactic-card`, `::: good-bad`, `::: facts-table-wrap`, `::: example-card`,
  `::: source-card`, `::: myth-callout`, `::: accordion title="Details"`,
  `::: info-panel severity=high`, `::: action-panel`, `::: appendix-links`, and
  `::: priority-group priority=high`, closed by `:::`. Use these to exercise
  Toolbox-style report components while keeping `report.md` canonical.
