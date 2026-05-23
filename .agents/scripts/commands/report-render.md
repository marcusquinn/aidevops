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

## Notes

- Markdown remains canonical; HTML is generated output.
- Evidence badges are limited to `verified`, `partial`, `inferred`, and `missing`.
- JSON reports use `evidence_badge` fields for the same badge values.
- `print-css` exposes the embedded print stylesheet for custom handoff workflows.
