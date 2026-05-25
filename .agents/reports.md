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
- **Render command**: `/report-render report.md` or
  `scripts/report-render-helper.sh render report.md --output report.html`.
- **Preview examples**: open `_reports/examples/index.html` locally after cloning
  the repo to inspect Markdown-first reports, style previews, and PDF exports.

<!-- AI-CONTEXT-END -->

## Routing

1. Identify the report goal, audience, decision, cadence, and evidence sources.
2. Load the matching family doc instead of duplicating domain expertise here.
3. Apply the shared citation, exporter, and `_reports/` output contracts.
4. Return Markdown as the canonical report source; derive exports only after the
   Markdown is reviewed.

## Creating Reports

1. Start with `reports/general.md` for audience, decision, evidence, anatomy, and
   quality gates.
2. Load the relevant domain doc for SEO/GEO, development, marketing, or business
   findings. Keep collection in the domain agent and report shaping here.
3. Save canonical report source as `report.md` or `report.json` under `_reports/`
   according to `reports/outputs.md`.
4. Render derived HTML/PDF handoffs with `/report-render` or
   `scripts/report-render-helper.sh`; do not hand-edit generated exports.

## Creating Report Agents

Use this when the same report will be repeated for a client, routine, product, or
internal operating cadence:

1. Read `reports/routine-handoff.md` and `tools/build-agent/build-agent.md`.
2. Define cadence, inputs, source IDs, privacy rules, deterministic collection
   commands, template/style, and verification gates.
3. Put repeatable collection in `run:` steps; use `agent:Reports` for evidence
   interpretation, narrative, recommendations, and follow-up tasks.
4. Store local/client-specific agents in `custom/`; only promote shared report
   agents into `.agents/` when the pattern is broadly reusable.

## Related

- `tools/document/document-creation.md` -- document creation and conversion.
- `tools/conversion/pandoc.md` -- Markdown, HTML, DOCX, and PDF conversion.
- `tools/pdf/overview.md` -- PDF processing tool selection.
- `tools/design/report-presentation.md` -- styled report presentation guidance.
