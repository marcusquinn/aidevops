# LLM Visibility Instructional Toolbox

::: report-cover
**Markdown-canonical LLM visibility playbook** with Toolbox-style cards, scorecards, source ledgers, and routine handoff.
:::

## Executive summary

LLM visibility work compounds when content engineering, authority signals, and technical crawlability are treated as one evidence system. {{evidence:verified}}

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**5**

Answer engines reported separately.
:::
::: stat-card
**3**

Tactic groups: on-page, technical, authority.
:::
::: stat-card
**1**

Canonical Markdown source.
:::
:::

## Highest impact tactics

::: facts-table-wrap

| Tactic | Evidence | Page-type fit | Verification |
|---|---|---|---|
| Earned third-party mentions | {{evidence:verified}} | SaaS, ecommerce, YMYL, local | Track AIO, Gemini, ChatGPT, AI Mode, and Perplexity separately |
| Direct answer in first paragraph | {{evidence:partial}} | Article, glossary, comparison, research/report | Prompt-run citation and snippet checks |
| Original statistics and source cards | {{evidence:verified}} | Research/report, comparison, use-case | Source ID appears in answer-engine citation |
| FAQPage schema | {{evidence:inferred}} | Hygiene only unless visible FAQ fits intent | Rich-result validation, not visibility lift claim |
:::

## On-page tactic card

::: tactic-card

### Direct-answer opening

- What: answer the query plainly in the first paragraph.
- Why: extractive answer systems need concise, quotable claims with nearby proof.
- How: pair answer, source ID, author/updated date, and supporting table.
- Verify: rerun per-engine prompts and compare cited URL movement.
:::

## Technical tactic card

::: tactic-card

### Bot-friendly first fetch

- What: SSR or pre-render important content, allow relevant AI crawlers, and keep FCP fast.
- Why: invisible content cannot be cited.
- How: crawl rendered and raw HTML, review robots.txt, segmented sitemap, and logs.
- Verify: monthly AI bot log analysis and fetch tests.
:::

## Authority tactic card

::: tactic-card

### Third-party corroboration

- What: make consistent entity facts visible on reputable review, community, video, and industry sites.
- Why: answer engines cross-check claims against external sources.
- How: build a source ledger across owned pages and third-party profiles.
- Verify: source breadth score and per-engine citation lines.
:::

## Myth callout

::: myth-callout

Myth: adding FAQPage schema is a primary GEO tactic. Fact: treat FAQPage as hygiene unless visible FAQ content genuinely matches page type and query fan-out.
:::

::: example-card
```text
Worker brief: update /compare/example with source IDs S-001 through S-004, visible citations, and per-engine retest steps.
```
:::

## Routine handoff

::: checklist-card

- Monthly: run prompt/query sets across AIO, Gemini, ChatGPT, AI Mode, and Perplexity.
- Quarterly: refresh source ledger and page-type weighting.
- Worker task: each remediation must include page path, source IDs, acceptance criteria, and re-test command.
:::
