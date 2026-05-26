---
description: SEO, GEO, SRO, and AI-search report routing
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SEO and GEO Reports

Use this doc for SEO audits, GEO strategy reports, AI-search scorecards,
citation monitoring, ranking opportunity reports, and search visibility reviews.
Route analysis to the SEO family; this report doc only standardises structure,
evidence, export, and handoff.

## Domain Routing

- Start with `seo.md` for SEO tool and subagent selection.
- Use `seo/seo-geo.md` for GEO strategy command flow.
- Use `seo/geo-strategy.md` for criteria coverage and retrieval-first analysis.
- Use `seo/ai-search-readiness.md` for end-to-end AI-search readiness.
- Use `seo/ai-search-report-template.md` for GEO and AI-search report sections.
- Use `seo/llm-visibility-instructional-report.md` when the request is an
  educational toolbox/playbook rather than a short audit.
- Use `seo/ai-search-kpi-template.md` for recurring scorecards.
- Use `seo/data-export.md`, `seo/google-search-console.md`,
  `seo/dataforseo.md`, or `seo/serper.md` for data collection details.

## Report Sections

1. Scope: domain, page set, intent clusters, competitor set, date range.
2. Method: tools, query/prompt sets, crawl inputs, engines tested, limitations.
3. Weighted scorecard: page type, retrieval eligibility, evidence strength,
   effort, confidence, freshness, third-party breadth, and priority.
4. Per-engine lines: AIO, Gemini, ChatGPT, AI Mode, Perplexity, and SERP data.
5. Findings: criteria gaps, fan-out gaps, citation behaviour, fact integrity,
   schema hygiene, and autonomous discoverability.
6. Roadmap: P0/P1/P2 recommendations with verification and source IDs.
7. Handoff: worker tasks, baseline re-test plan, custom agent, or routine.

## Evidence Rules

- Separate observed search output from inferred opportunity.
- Cite every visibility, ranking, citation, or traffic claim with source IDs.
- Keep per-engine evidence separate before summarising across engines.
- Treat schema validation as hygiene unless it blocks eligibility or clarity.
- Record capture dates because AI-search and SERP output changes quickly.

## Generic and Client-Custom SEO/GEO Reports

- **Generic guidance reports** may combine `seo/llm-visibility-instructional-report.md`,
  the SEO/GEO pattern docs, and curated source material into a chaptered toolbox.
  Label source material and assumptions clearly.
- **Client-custom reports** must collect live/client evidence first: target pages,
  page types, intent clusters, crawl/indexability, visible content, schema/logs,
  analytics/Search Console exports if available, review/profile parity, backlinks
  or citations, and per-engine AIO/Gemini/ChatGPT/AI Mode/Perplexity lines.
- Use the weighted scorecard from `seo/ai-search-scoring.md` before writing the
  roadmap. Recommendations must cite source IDs and be weighted by page type;
  never apply a flat tactic list to every URL.
- If recurring monitoring is useful, hand off to `reports/routine-handoff.md` with
  deterministic collection steps before any `agent:Reports` interpretation step.

## Export Notes

- Use `reports/citations.md` for inline source IDs and evidence ledger format.
- Use `reports/exporters.md` for Markdown, HTML, and PDF export bundles.
- Use `tools/design/report-presentation.md` for scorecards, source cards,
  evidence badges, tables, and print-safe report presentation.
