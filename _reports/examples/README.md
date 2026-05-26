<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Versioned Report Examples

These examples are reviewed, versioned report examples. They demonstrate the
Markdown-first report contract from `.agents/reports/outputs.md`:

- `report.md` is canonical.
- `report.html` and `style-previews/*.html` are derived examples.
- `*-a4.pdf` and `*-16-9.pdf` are reviewed portrait and landscape exports;
  do not keep duplicate unsuffixed PDF exports beside them.

Open `index.html` in this directory to browse example sets, rendered themes, and
their A4, US Letter, and slides PDF exports from one preview UI.

## Examples

| Directory | Purpose |
|-----------|---------|
| `llm-visibility-toolbox/` | Generic LLM visibility playbook with Toolbox-style cards and evidence patterns. |
| `client-ai-search-audit/` | Placeholder-safe client-custom report structure with per-engine findings and source ledger. |
| `brand-style-guide/` | Brand-library presentation report for DESIGN.md tokens, components, constraints, and agent handoff. |
| `style-previews/` | Compact component stress-test for comparing DESIGN.md-backed visual styles. |

## Regenerate

```bash
.agents/scripts/report-render-helper.sh render _reports/examples/llm-visibility-toolbox/report.md \
  --template axel \
  --pdf-profile a4 \
  --output _reports/examples/llm-visibility-toolbox/report.html

.agents/scripts/report-render-helper.sh render _reports/examples/client-ai-search-audit/report.md \
  --template ibm \
  --pdf-profile a4 \
  --output _reports/examples/client-ai-search-audit/report.html

.agents/scripts/report-render-helper.sh render _reports/examples/brand-style-guide/report.md \
  --template signal-agency \
  --pdf-profile a4 \
  --output _reports/examples/brand-style-guide/signal-agency.html
```

For style comparisons, render the same `style-previews/report.md` with any name
from `.agents/scripts/report-render-helper.sh list-templates`.

When exporting committed PDFs with Chrome/Chromium headless, suppress browser
date/title/URL/page-number chrome:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new \
  --no-pdf-header-footer \
  --print-to-pdf=_reports/examples/style-previews/<name>-a4.pdf \
  file://$PWD/_reports/examples/style-previews/<name>.html
```

Do not commit exports with browser-generated headers or footers; report chrome
must come from the renderer HTML/CSS only.

Dark-capable styles also include explicit light and dark preview files. List
those styles with:

```bash
.agents/scripts/report-render-helper.sh list-dark-templates
```

Then render both variants with `--theme light` and `--theme dark` to check panel,
card, table, badge, and callout inversions.
