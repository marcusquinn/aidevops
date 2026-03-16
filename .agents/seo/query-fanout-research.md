---
name: query-fanout-research
description: Model thematic fan-out sub-queries and map content coverage across priority intent clusters
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

# Query Fan-Out Research

Simulate how AI systems decompose broad prompts into sub-queries and use that map to guide coverage.

## Quick Reference

- Purpose: expose hidden sub-query themes behind user intents
- Inputs: seed intent, market context, existing page set
- Outputs: fan-out map, priority tiers, coverage matrix, implementation backlog

## Workflow

### 1) Generate theme branches

- Start with one core user intent
- Produce 3-7 thematic branches (selection criteria, trust checks, risk checks, alternatives, constraints)
- Keep each branch as a distinct retrieval objective

### 2) Create actionable sub-queries

- Generate sub-queries per theme with clear purpose tags
- Tag each sub-query: high, medium, low priority
- Include common modifiers (location, budget, urgency, compliance, integration)

### 2.5) Model `site:` retrieval stages

- Treat fan-out as a 3-stage retrieval model:
  broad discovery -> site-specific deep-dive -> third-party validation
- Stage 1 (broad discovery): open-web category and comparison queries
  (for example, "best ATS for SMB [year]")
- Stage 2 (site-specific deep-dive): domain-scoped checks such as
  `site:brand.com pricing`, `site:brand.com integrations`,
  `site:brand.com enterprise features`
- Stage 3 (third-party validation): independent source checks such as
  `site:g2.com brand review`, `site:capterra.com brand pricing`,
  `site:trustradius.com brand alternatives`
- Predict which branch needs each stage before content production;
  product claims need Stage 2 and trust/risk claims need Stage 3
- Build branch maps that show where open search is sufficient versus where
  domain-scoped retrieval and review-platform corroboration are required

### 3) Map pages to branches

- Link each sub-query to best existing page
- Mark branch coverage: complete, partial, missing
- Flag where one page tries to cover too many unrelated branches

### 4) Build remediation plan

- Add concise sections for partial branches
- Create focused support pages only for genuinely missing high-priority branches
- Add internal links that mirror fan-out relationships

### 5) Validate with retrieval simulation

- Re-run fan-out prompts and compare page/sentence match quality
- Confirm top branches are answered by high-confidence sections
- Record unresolved branches for next sprint
- Include explicit simulation runs for each retrieval stage and record
  citation/source mix shifts after updates

## Site-Scoped Retrieval in Fan-Out

Frontier AI models (observed in GPT-5.4-thinking and similar) use `site:` operator queries extensively during fan-out retrieval. A single user prompt can generate 10+ sub-queries, many of which target specific domains directly rather than searching the open web.

### 3-Stage Retrieval Model

AI fan-out typically follows three stages:

1. **Broad discovery** (queries 1-3): open web searches using category terms, brand names, and comparison phrases to identify relevant domains. Example: `best ATS software [year]`, `[BrandA] vs [BrandB] applicant tracking`.
2. **Site-specific deep-dive** (queries 4-10): `site:domain.com` queries targeting each discovered brand's own site to extract product details, pricing, features, and differentiators. Example: `site:greenhouse.com enterprise ATS features`, `site:workable.com pricing plans [year]`.
3. **Third-party validation** (queries 11-13): `site:` queries targeting review platforms (G2, Capterra, TrustRadius) to cross-reference claims with independent evaluations. Example: `site:g2.com greenhouse ATS reviews`, `site:capterra.com workable pricing`.

### Modelling Site-Scoped Sub-Queries

When building a fan-out map, classify each sub-query by retrieval scope:

- **Open-web sub-queries**: discovery-stage queries where the model has not yet committed to a domain. These are influenced by traditional SEO ranking.
- **Domain-scoped sub-queries**: `site:yourdomain.com` queries where the model is searching your content specifically. These bypass SERP ranking entirely — the model already chose your domain and is extracting detail. Content architecture and on-site searchability determine success.
- **Third-party validation sub-queries**: `site:g2.com` or `site:capterra.com` queries where the model seeks independent confirmation. Your review platform profiles, not your own site, determine what gets retrieved.

### Implications for Coverage Mapping

- In step 3 (Map pages to branches), tag each branch by its likely retrieval scope: open-web, domain-scoped, or third-party
- Domain-scoped branches require pages that are individually addressable and contain self-contained answers — the model is searching your site like a database, not reading a narrative
- Third-party branches require complete, current review platform profiles with the same canonical facts as your primary site
- A branch marked "complete" on your site but absent from review platforms is only 2/3 covered

## Guardrails

- Optimize for thematic completeness, not maximal query count
- Avoid duplicate pages targeting near-identical branches
- Keep branch language aligned with user phrasing from real queries
- Re-baseline when SERP intent or product positioning changes
- Ensure domain-scoped branches have pages that return relevant results for `site:yourdomain.com [category] [feature] [year]` query patterns
- Verify third-party review profiles contain the same facts as primary site content

## Related Subagents

- `geo-strategy.md` for criteria-led optimization strategy
- `sro-grounding.md` for snippet and selection tuning
- `keyword-mapper.md` for keyword-to-section placement
