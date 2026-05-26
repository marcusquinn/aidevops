<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LLM Visibility Instructional Report

Use this when the user wants a comprehensive educational playbook rather than a
short audit. The output should teach the reader how LLM visibility works, why
each tactic matters, how to implement it, and how to verify impact.

## Report Shape

1. **Executive summary** -- what changed in AI search behaviour and which levers
   matter most.
2. **Why this matters now** -- explain answer engines, citations, mentions,
   retrieval, grounding, and source corroboration in plain language.
3. **Highest-impact tactics** -- ranked list with evidence badges and page-type
   applicability.
4. **On-page content tactics** -- direct-answer openings, question headings,
   source cards, statistics, expert quotes, tables, comparison pages, glossary,
   use-case pages, freshness, original research, and author signals.
5. **Technical tactics** -- robots policy, SSR/pre-rendering, bot-friendly first
   fetch, segmented sitemap, stable entity graph, bot logs, FCP, Open Graph, and
   schema as hygiene.
6. **Off-page and authority tactics** -- community, reviews, listicles, digital
   PR, third-party profiles, Wikipedia/Wikidata where appropriate, podcasts,
   partnerships, LinkedIn, video/transcripts, and entity consistency.
7. **Format and experimental tactics** -- PDFs with HTML host pages, datasets,
   calculators, embeddable charts, multilingual content, and transcript assets.
8. **Industry-specific guidance** -- SaaS, ecommerce, healthcare/YMYL, local,
   professional services, and content/publisher variants.
9. **Myths and caveats** -- de-emphasise flat FAQ/schema recommendations and
   unsupported AI share-of-voice claims.
10. **Implementation roadmap** -- P0/P1/P2 tasks with owner, effort, source IDs,
     and verification.
11. **Appendices and source data** -- link supplementary prompt exports, crawl
    tables, screenshots, source ledgers, and companion reports when available.

## Tactic Card Contract

Every material tactic should include:

| Field | Requirement |
|-------|-------------|
| Tactic | Named action, not a vague theme. |
| Evidence badge | `verified`, `partial`, `inferred`, or `missing` for renderer compatibility; optionally map to RCT/Strong/Vendor/Practitioner/Hygiene in prose. |
| What | One-sentence definition. |
| Why | Retrieval, citation, trust, conversion, or risk mechanism. |
| How | Concrete implementation steps. |
| Page-type fit | Use `seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md`. |
| Example | Short before/after, code snippet, table, or content pattern. |
| Verification | Crawl, log, schema, prompt, SERP, analytics, or per-engine retest. |
| Source IDs | Cite evidence ledger IDs inline. |

## Toolbox Component Requirements

For long playbooks, include examples of: links, numbered steps, accordions,
summary-stat rows, KPI cards, impact/evidence/action panels,
severity/priority colour keys, code blocks, chapter separators, quotes,
good/bad examples, checkbox lists, source links, source ledgers, visibility bar
charts, privacy notes, anchor links, and appendix links. Use the report renderer
component vocabulary from `reports/general.md` so the Markdown remains canonical.

## Evidence and Weighting Rules

- Use `ai-search-scoring.md` for weighted priority: business value, page-type
  applicability, retrieval eligibility, evidence strength, effort, confidence,
  freshness, third-party breadth, and engine-specific mention/citation behaviour.
- Report AIO, Gemini, ChatGPT, AI Mode, and Perplexity separately before any
  aggregate summary.
- Treat `FAQPage` and schema work as hygiene unless visible content and page type
  justify the tactic.
- Label unsupported claims as assumptions or backlog; do not present them as
  findings.
- Use `llm-visibility-source-accrual.md` before writing source-backed playbooks or
  client reports; collect source IDs first, then interpret.
- Keep client-facing artifacts dossier-like: manifest → KPI cards → decision line
  → per-engine table and bars → source ledger → priority cards → preserve/fix →
  implementation brief → owner checklist.

## Renderer Handoff

Recommended export for the instructional playbook:

```bash
.agents/scripts/report-render-helper.sh sample instructional-seo-geo > _reports/drafts/llm-visibility-toolbox/report.md
.agents/scripts/report-render-helper.sh render _reports/drafts/llm-visibility-toolbox/report.md \
  --template axel \
  --pdf-profile a4 \
  --output _reports/drafts/llm-visibility-toolbox/report.html
```

Use `--pdf-profile letter` for US Letter, or
`--pdf-profile slides-16-9-1|2|3` for PDF presentation formats. Keep one HTML
preview; page size variants belong to PDF output only.

## Related

- `geo-strategy.md` -- GEO criteria and weighted implementation plan.
- `llm-visibility-source-accrual.md` -- source-site and evidence-ledger accrual.
- `ai-search-report-template.md` -- concise audit/report template.
- `ai-search-scoring.md` -- scoring and per-engine evidence contract.
- `seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md` -- page-type
  tactic weighting.
