<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1536: Add site: query optimization intelligence to GEO agents

## Session Origin

Interactive session, 2026-03-16. User shared X post by @chris_nectiv showing GPT-5.4-thinking fan-out query logs with heavy `site:` operator usage. Screenshot showed 13 fan-out queries for a single ATS comparison prompt, with queries 4-10 using `site:domain.com` to pull content directly from brand domains, and queries 11-13 using `site:g2.com` for third-party validation.

## What

Update the SEO/GEO agent suite to incorporate intelligence about AI models using `site:` operator queries as a primary retrieval mechanism. This is a content strategy update across multiple existing subagents, not a new subagent.

## Why

GPT-5.4 (and likely other frontier models) are using `site:` search queries extensively during fan-out retrieval. This means:

1. On-site content is now a **direct** AI citation source via domain-scoped search, bypassing traditional SERP ranking for the site-specific retrieval stage
2. The retrieval pattern follows a 3-stage model our agents don't currently document
3. Third-party review platforms (G2, Capterra) are being used as validation sources via `site:` queries
4. Content architecture needs to be optimised for domain-scoped searchability, not just traditional SEO

Our current GEO agents are strong on criteria alignment, snippet survivability, and fan-out modelling, but have no awareness of `site:` as a retrieval mechanism or the 3-stage retrieval pattern.

## How

Update these existing files (no new files needed):

### 1. `seo/query-fanout-research.md`

- Add a section on `site:` operator queries as a fan-out pattern
- Document the 3-stage retrieval model: broad discovery -> site-specific deep-dive (`site:domain.com`) -> third-party validation (`site:g2.com`, `site:capterra.com`)
- Add guidance on modelling which sub-queries will use `site:` vs open search

### 2. `seo/geo-strategy.md`

- Add "site-searchable content architecture" to Implementation Rules
- Guidance: key product/feature pages must return relevant results for `site:yourdomain.com [category] features [year]` type queries
- Add third-party platform strategy: ensure G2/Capterra/TrustRadius profiles are complete, current, and contain the same canonical facts as the primary site

### 3. `seo/sro-grounding.md`

- Add guidance on optimising for domain-scoped retrieval (the model is searching your site specifically, not the open web)
- Page titles, meta descriptions, and H1s should contain category terms that match likely `site:` query patterns

### 4. `seo/ai-search-readiness.md`

- Add a new check to Phase 0 or Phase 1: "site: query readiness" — can the model find key claims by running `site:yourdomain.com [product category] features`?
- Add third-party citation readiness to Phase 6: are review platform profiles current?

### 5. `seo/seo-audit-skill/references/aeo-geo-patterns.md`

- Add a new GEO pattern: "Site-Searchable Product Block" — structured content block optimised for domain-scoped AI retrieval
- Add UTM/citation attribution tracking guidance

### 6. `seo/ai-agent-discovery.md`

- Add `site:` query simulation to the discovery task workflow — test whether an agent using `site:yourdomain.com` queries can find key information

## Acceptance Criteria

1. All 6 files updated with site: query intelligence
2. The 3-stage retrieval model (broad -> site-specific -> third-party) is documented in query-fanout-research.md
3. A "site: query readiness" audit check exists in ai-search-readiness.md
4. Third-party review platform strategy is documented in geo-strategy.md
5. No new files created — all updates are additive to existing subagents
6. All updated files pass markdownlint

## Context

Source: https://x.com/chris_nectiv/status/2033513896984604857

Key data from screenshot:
- Model: gpt-5-4-thinking
- Fan-out queries: 13
- Queries 1-3: broad discovery (brand names, category terms)
- Queries 4-10: `site:` targeting individual brand domains (greenhouse.com, ashbyhq.com, workable.com, smartrecruiters.com, pinpointhq.com, lever.co)
- Queries 11-13: `site:g2.com` for third-party reviews
- Cited sources: 6
- UTM coverage: 6/6
- All cited domains were hit with a `site:` query

The implication: "Topical authority + Parasite SEO = AI Citations" — brands need both strong on-site content AND presence on third-party review/comparison platforms to maximise AI citation likelihood.
