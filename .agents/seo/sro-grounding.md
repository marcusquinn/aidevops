---
name: sro-grounding
description: Optimize Selection Rate by improving grounding snippet eligibility, relevance density, and citation survivability
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SRO Grounding

SRO (Selection Rate Optimization): whether a source gets selected into grounded context, not only whether it ranks. AI retrieval uses fixed context budgets — higher-relevance sources get larger share; key facts buried deep in long pages have low survival rates. `site:brand.com` probes require page metadata to match category/feature terms.

## SRO Workflow

1. **Baseline** — collect snippets for representative intents; tag type; identify what wins vs never survives
2. **Improve snippet fitness** — rewrite critical statements as standalone factual sentences; move essential facts to top-of-page
3. **Reduce structural noise** — minimize boilerplate near top content; keep heading hierarchy clean
4. **Cover fan-out angles** — map sub-questions retrieval systems dispatch per intent; ensure concise answers per angle; add internal links to deeper evidence
5. **Validate** — re-run same intent set after updates; compare snippet quality and citation persistence; re-test after index/model updates (grounding behavior is transient)

## Content Rules

**Snippet eligibility:**

- Key facts in opening sections — not buried deep
- Short declarative sentences over promotional phrasing
- Explicit numerics and qualifiers (thresholds, limits, timelines)
- Lists/tables only when they preserve factual precision
- Policy, pricing, and capability statements on a defined refresh cadence
- Every key fact self-contained — no pronoun/antecedent dependencies

**Domain-scoped retrieval** (`site:` queries — pages compete against each other, not competitors):

- **Titles/H1s** must contain category terms — "Enterprise ATS Features & Capabilities" matches `site:yourdomain.com enterprise ATS features`; "Our Platform" does not
- **Meta descriptions** as factual summaries with category terms, not marketing taglines
- **One authoritative page per topic** — don't spread facts across partially-matching pages
- **Descriptive headings** matching likely query terms (`## Pricing Plans`) — not creative headings (`## Why We're Different`)

## Common Failure Modes

- Key claims only deep in the page
- Contradictory facts across pages dilute confidence
- Overlong narrative buries actionable information
- Snippet candidates rely on pronouns with missing antecedents
- Page titles use brand-centric language instead of category terms
- Key product pages lack factual meta descriptions

## Related Subagents

- `geo-strategy.md` — criteria extraction and strategy
- `query-fanout-research.md` — thematic decomposition
- `ai-hallucination-defense.md` — consistency and evidence hygiene
