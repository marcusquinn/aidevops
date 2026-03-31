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

Simulate how AI systems decompose broad prompts into sub-queries, then use that map to guide content coverage.

## Quick Reference

- Purpose: expose hidden sub-query themes behind user intents
- Inputs: seed intent, market context, existing page set
- Outputs: fan-out map, priority tiers, coverage matrix, implementation backlog

## Core Model

Treat fan-out as a 3-stage retrieval model. Frontier AI systems (observed in GPT-5.4-thinking and similar) often generate 10+ sub-queries from one prompt, including `site:` queries that target specific domains directly.

1. **Broad discovery**: open-web category and comparison queries such as `best ATS for SMB [year]` or `[BrandA] vs [BrandB] applicant tracking`
2. **Site-specific deep-dive**: domain-scoped queries such as `site:brand.com pricing`, `site:brand.com integrations`, `site:brand.com enterprise features`
3. **Third-party validation**: independent checks such as `site:g2.com brand review`, `site:capterra.com brand pricing`, `site:trustradius.com brand alternatives`

Predict which stage each branch needs before content production. Product claims usually need Stage 2; trust and risk claims usually need Stage 3.

## Workflow

### 1) Generate theme branches

- Start with one core user intent
- Produce 3-7 thematic branches (selection criteria, trust checks, risk checks, alternatives, constraints)
- Keep each branch as a distinct retrieval objective

### 2) Create actionable sub-queries

- Generate sub-queries per theme with clear purpose tags
- Tag each sub-query: high, medium, low priority
- Include common modifiers: location, budget, urgency, compliance, integration
- Classify each sub-query by retrieval scope:
  - **Open-web**: discovery-stage queries influenced by traditional SEO ranking
  - **Domain-scoped**: `site:yourdomain.com` queries where the model has already chosen your domain and is extracting detail; content architecture and on-site searchability determine success
  - **Third-party validation**: `site:g2.com` or `site:capterra.com` queries where review platform profiles, not your site, determine retrieval

### 3) Map pages to branches

- Link each sub-query to the best existing page
- Mark branch coverage: complete, partial, missing
- Tag each branch by likely retrieval scope: open-web, domain-scoped, or third-party
- Flag where one page tries to cover too many unrelated branches
- Treat a branch as incomplete if it is covered on your site but missing from key review platforms; that is only 2/3 coverage

### 4) Build remediation plan

- Add concise sections for partial branches
- Create focused support pages only for genuinely missing high-priority branches
- Add internal links that mirror fan-out relationships
- Ensure domain-scoped branches have individually addressable pages with self-contained answers; the model is searching your site like a database, not reading a narrative
- Ensure third-party branches have complete, current review platform profiles with the same canonical facts as your primary site content

### 5) Validate with retrieval simulation

- Re-run fan-out prompts and compare page/sentence match quality
- Confirm top branches are answered by high-confidence sections
- Record unresolved branches for the next sprint
- Run explicit simulations for each retrieval stage and record citation/source mix shifts after updates

## Guardrails

- Optimize for thematic completeness, not maximal query count
- Avoid duplicate pages targeting near-identical branches
- Keep branch language aligned with real user phrasing
- Re-baseline when SERP intent or product positioning changes
- Ensure domain-scoped branches return relevant results for `site:yourdomain.com [category] [feature] [year]` query patterns
- Verify third-party review profiles contain the same facts as primary site content

## Related Subagents

- `geo-strategy.md` for criteria-led optimization strategy
- `sro-grounding.md` for snippet and selection tuning
- `keyword-mapper.md` for keyword-to-section placement
