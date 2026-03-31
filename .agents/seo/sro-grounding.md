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

# SRO Grounding

Selection Rate Optimization (SRO): whether a source gets selected into grounded context, not only whether it ranks.

## Quick Reference

- **Purpose**: improve source selection share in AI retrieval pipelines
- **Core metric**: Selection Rate (selected appearances / available retrieval opportunities)
- **Inputs**: query themes, ranked pages, extracted snippets, page structure and copy
- **Outputs**: snippet optimization recommendations, structural cleanup, SRO test plan

## Working Model

- AI retrieval works with fixed context budgets — higher-relevance sources get larger share
- Long pages suffer low content survival when key facts are buried
- Domain-scoped probes (`site:brand.com ...`) depend on page metadata matching category/feature modifiers

## SRO Workflow

1. **Baseline** — collect snippets for representative intents; tag type (lead paragraph, list item, heading-adjacent, table row); identify what wins vs never survives
2. **Improve snippet fitness** — rewrite critical statements as standalone factual sentences; move essential facts to top-of-page; reduce context dependency
3. **Reduce structural noise** — minimize boilerplate near top content blocks; keep heading hierarchy clean; avoid decorative text competing with facts
4. **Cover fan-out angles** — map sub-questions retrieval systems may dispatch per intent; ensure concise answers for each angle; add internal links to deeper evidence
5. **Validate** — re-run same intent set after updates; compare snippet quality, coverage breadth, citation persistence; keep SRO changelog tied to page revisions; re-test after index/model updates (grounding behavior is transient)

## Content Rules

**Snippet eligibility:**

- Key facts in opening sections — not buried deep in the page
- Short declarative sentences over vague promotional phrasing
- Explicit numerics and qualifiers (thresholds, limits, timelines)
- Lists/tables only when they preserve factual precision
- Policy, pricing, and capability statements kept current on a defined refresh cadence
- Every key fact self-contained — no pronoun/antecedent dependencies

**Domain-scoped retrieval** (`site:` queries search your site, not the open web — pages compete against each other, not competitors):

- **Titles/H1s** must contain category terms explicitly — "Enterprise ATS Features & Capabilities" matches `site:yourdomain.com enterprise ATS features`; "Our Platform" does not
- **Meta descriptions** as factual summaries with category terms, not marketing taglines — they serve as retrieval previews for page selection
- **One authoritative page per topic** — don't spread facts across partially-matching pages
- **Descriptive headings** matching likely query terms (`## Pricing Plans`, `## Enterprise Features`) — not creative headings (`## Why We're Different`)

## Common Failure Modes

- Important claims only deep in the page
- Contradictory facts across pages dilute confidence
- Overlong narrative buries actionable information
- Snippet candidates rely on pronouns with missing antecedents
- Page titles use brand-centric language instead of category terms matching `site:` patterns
- Key product pages lack factual meta descriptions

## Related Subagents

- `geo-strategy.md` — criteria extraction and strategy
- `query-fanout-research.md` — thematic decomposition
- `ai-hallucination-defense.md` — consistency and evidence hygiene
