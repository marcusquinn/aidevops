---
description: General report orchestration and shared report anatomy
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# General Reports

Use this doc for report briefs, report outlines, cross-domain reports, and
quality checks before export. Keep domain analysis in the domain agents; this
agent owns report structure, evidence traceability, and handoff contracts.

## Intake

Collect only what changes the report outcome:

- Audience, decision, deadline, cadence, and confidentiality level.
- Report type: one-off, baseline, recurring scorecard, audit, board pack,
  campaign review, incident review, or client handoff.
- Evidence sources, capture dates, tool outputs, and known gaps.
- Required exports: Markdown only, HTML, PDF, DOCX, slides, or archive bundle.
- Follow-up path: worker tasks, custom client agent, scheduled routine, or none.

## Report Anatomy

Use this default shape unless the domain doc provides a better template:

1. Cover metadata: client/project, scope, date range, author, version.
2. Executive summary: decision, status, top findings, recommended next action.
3. Method: data sources, collection commands, assumptions, and limitations.
4. Findings: evidence-backed observations with source IDs and confidence.
5. Recommendations: owner, priority, expected outcome, verification path.
6. Evidence ledger: source IDs, dates, URLs or paths, and supported claims.
7. Appendix: raw tables, screenshots, exports, unresolved questions.
8. Handoff: worker-ready tasks, routine schedule, or custom-agent prompt.

## Routing Matrix

| Report focus | Load next | Keep here |
|--------------|-----------|-----------|
| SEO, GEO, AI-search visibility | `reports/seo-geo.md` | Structure, citations, export |
| Engineering, code quality, delivery | `reports/development.md` | Structure, citations, export |
| Campaigns, content, CRO, sales | `reports/marketing.md` | Structure, citations, export |
| Finance, operations, company runners | `reports/business.md` | Structure, citations, export |
| Export format or PDF styling | `reports/exporters.md` | Canonical Markdown contract |
| Recurring collection or custom client agent | `reports/routine-handoff.md` | Handoff completeness |

## Quality Gate

- Every material claim has an inline citation or an explicit `unsupported` note.
- Recommendations are decision-ready: owner, priority, rationale, verification.
- Markdown remains canonical; derived exports are not hand-edited.
- Public output replaces private paths, private repo names, and local machine
  details with placeholders.
- Follow-up tasks include file/page paths when known, reference patterns, and
  verification commands.

## Related

- `reports/citations.md` -- inline citations and optional `citations.json`.
- `reports/exporters.md` -- Markdown to HTML/PDF/export bundle contract.
- `reports/routine-handoff.md` -- recurring routines and custom client agents.
- `reports/outputs.md` -- `_reports/` directory and artifact contract.
