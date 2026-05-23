---
name: reports
description: Report planning, evidence contracts, exporters, and routine handoffs
mode: subagent
subagents:
  - general
  - seo-geo
  - development
  - marketing
  - business
  - citations
  - exporters
  - routine-handoff
  - outputs
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reports Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Turn evidence into decision-ready reports with reusable contracts.
- **Use first**: `reports/general.md` for report shape and routing.
- **Domain routes**: `reports/seo-geo.md`, `reports/development.md`,
  `reports/marketing.md`, and `reports/business.md`.
- **Shared contracts**: `reports/citations.md`, `reports/exporters.md`,
  `reports/routine-handoff.md`, and `reports/outputs.md`.

<!-- AI-CONTEXT-END -->

## Routing

1. Identify the report goal, audience, decision, cadence, and evidence sources.
2. Load the matching family doc instead of duplicating domain expertise here.
3. Apply the shared citation, exporter, and `_reports/` output contracts.
4. Return Markdown as the canonical report source; derive exports only after the
   Markdown is reviewed.

## Related

- `tools/document/document-creation.md` -- document creation and conversion.
- `tools/conversion/pandoc.md` -- Markdown, HTML, DOCX, and PDF conversion.
- `tools/pdf/overview.md` -- PDF processing tool selection.
- `tools/design/report-presentation.md` -- styled report presentation guidance.
