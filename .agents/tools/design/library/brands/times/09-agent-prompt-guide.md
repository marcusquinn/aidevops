<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Polymarket Times: Agent Prompt Guide

Render with:

```bash
.agents/scripts/report-render-helper.sh render report.md --template times --pdf-profile a4 --output report.html
```

Prompt style:

> Render this Markdown-first report in the Polymarket Times style: Playfair Display masthead/headings, Georgia editorial body copy, Menlo ticker/data/code UI, cream newsprint background, black rules, square panels, market-green positive indicators, red negative indicators, and PDF-safe newspaper tables.

For slides, keep `report.html` as the preview and export PDF with `--pdf-profile slides-16-9-1`, `slides-16-9-2`, or `slides-16-9-3`.
