---
description: Markdown-first report export contract for HTML, PDF, and bundles
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Exporter Contract

Use Markdown as the canonical report source. HTML, PDF, DOCX, screenshots, and
archives are derived artifacts that can be regenerated from `report.md` and its
assets. Do not automatically install dependencies during report export.

## Source and Output Layout

Use the `_reports/` layout from `reports/outputs.md`:

```text
_reports/drafts/<report-slug>/report.md
_reports/drafts/<report-slug>/citations.json
_reports/drafts/<report-slug>/assets/
_reports/published/<report-slug>/report.md
_reports/published/<report-slug>/report.html
_reports/published/<report-slug>/report.pdf
```

## Export Rules

- Edit `report.md`, not derived HTML or PDF files.
- Keep `citations.json` optional, but preserve inline citations in every export.
- Keep generated drafts, indexes, and published bundles out of git unless a
  maintainer explicitly promotes a small fixture or template.
- Check dependency availability before export; report missing tools and the
  manual install command, but do not run installs automatically.
- Prefer deterministic commands in `run:` routines for collection and export.
- Run privacy checks before publishing or attaching a bundle.
- Default PDF output is A4 portrait. Use Letter portrait only when required by
  the recipient, and use 16:9 landscape profiles for PDF presentation exports.
- Keep a single `report.html` preview per report. Do not create separate A4,
  Letter, or slides HTML variants; page profiles are print/PDF settings.
- Prefer the report renderer profiles before raw Pandoc PDF output when visual
  fidelity matters:
  `report-render-helper.sh render report.md --template axel --pdf-profile a4 --output report.html`.

## Tool Routing

| Need | Route |
|------|-------|
| Create or convert documents | `tools/document/document-creation.md` |
| Markdown to HTML, DOCX, EPUB, or PDF via Pandoc | `tools/conversion/pandoc.md` |
| PDF manipulation, extraction, signatures, or form work | `tools/pdf/overview.md` |
| Complex PDF to Markdown or JSON | `tools/conversion/mineru.md` |
| OCR or scanned PDF handling | `tools/ocr/overview.md` |
| Report visual system, print CSS, and components | `tools/design/report-presentation.md` |

## Built-in PDF Profiles

| Profile | Purpose |
|---------|---------|
| `a4` | Default A4 portrait PDF CSS. |
| `letter` | US Letter portrait PDF CSS. |
| `slides-16-9-1` | 16:9 landscape PDF deck with one content column. |
| `slides-16-9-2` | 16:9 landscape PDF deck with two content columns. |
| `slides-16-9-3` | 16:9 landscape PDF deck with three content columns. |

## Suggested Export Flow

1. Produce `report.md` with inline citations and an evidence ledger.
2. Validate citations and privacy with `reports/citations.md`.
3. Check tool availability with the selected helper or `pandoc --version`.
4. Generate HTML and PDF into `_reports/drafts/<report-slug>/`.
5. Review screen, print, citations, links, tables, and accessibility.
6. Copy reviewed artifacts to `_reports/published/<report-slug>/`.

## Presentation Requirements

- Use `tools/design/report-presentation.md` for component naming, report tokens,
  print CSS, evidence badges, source cards, and accessibility checks.
- HTML must remain readable without JavaScript.
- PDF must preserve source labels, table captions, link targets, and grayscale
  meaning for status badges.
- Charts need text summaries or data-table fallbacks.

## Related

- `reports/citations.md` -- citation and source ledger contract.
- `reports/routine-handoff.md` -- deterministic `run:` collection/export.
- `reports/outputs.md` -- `_reports/` artifact contract.
