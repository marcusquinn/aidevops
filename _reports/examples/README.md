<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Versioned Report Examples

These examples are reviewed, versioned report examples. They demonstrate the
Markdown-first report contract from `.agents/reports/outputs.md`:

- `report.md` is canonical.
- `report.html` and `style-previews/*.html` are derived examples.
- PDFs are generated on demand with `--pdf-profile`; do not hand-edit exports.

## Examples

| Directory | Purpose |
|-----------|---------|
| `llm-visibility-toolbox/` | Generic LLM visibility playbook with Toolbox-style cards and evidence patterns. |
| `client-ai-search-audit/` | Placeholder-safe client-custom report structure with per-engine findings and source ledger. |
| `style-showcase/` | Compact component stress-test for comparing DESIGN.md-backed visual styles. |

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
```

For style comparisons, render the same `style-showcase/report.md` with any name
from `.agents/scripts/report-render-helper.sh list-templates`.

Dark-capable styles also include explicit light and dark preview files. List
those styles with:

```bash
.agents/scripts/report-render-helper.sh list-dark-templates
```

Then render both variants with `--theme light` and `--theme dark` to check panel,
card, table, badge, and callout inversions.
