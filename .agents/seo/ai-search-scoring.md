<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Search Scoring

Use this scoring model to prioritise SEO, AEO, and GEO recommendations for
AI-search visibility. Score per page, per intent cluster, and per engine line;
do not collapse material findings into a single aggregate AI Share of Voice.

## Weighted Scorecard

| Dimension | Weight | Score 0-5 evidence |
|-----------|--------|--------------------|
| Business value | 20% | Revenue, lead quality, retention, or strategic importance of the intent/page. |
| Page-type applicability | 15% | Fit against `seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md`. |
| Retrieval eligibility | 15% | Page can be discovered, indexed, crawled, and matched to grounded queries. |
| Evidence strength | 15% | Claims have source IDs, visible proof, dated facts, and corroboration. |
| Engine-specific mention/citation behaviour | 10% | Per-engine mention, citation, or exclusion patterns are measured separately. |
| Third-party breadth | 10% | Review sites, directories, research, partner pages, or authoritative references support the claim. |
| Freshness | 5% | Facts, reviews, pricing, and methodology are current for the query. |
| Confidence | 5% | Recommendation is supported by repeatable evidence, not one volatile prompt snapshot. |
| Effort | 5% | Lower effort receives higher priority when impact and confidence are similar. |

Weighted priority score:

```text
sum(score_0_to_5 * weight) / 5 = priority percentage
```

## Scoring Dimensions

### Business value

- Score `5`: revenue-critical page or buying intent with proven conversion
  value.
- Score `3`: assists discovery, nurture, or trust but has indirect commercial
  value.
- Score `1`: low-value informational page with no clear business outcome.

### Page-type applicability

- Score against the matrix tags: missing `required` tactics reduce priority
  confidence and raise implementation urgency.
- Penalise recommendations that apply a tactic marked `avoid` for the page
  type.
- Treat schema and `FAQPage` work as `hygiene` unless visible content gaps are
  already solved.

### Retrieval eligibility

- Confirm indexability, canonical status, internal links, crawler access, and
  query-language alignment.
- Separate retrieval problems from answer wording problems; an unindexed page
  cannot be reliably cited.

### Evidence strength

- Every material recommendation must reference one or more source IDs from an
  evidence ledger.
- Strong evidence includes dated primary facts, screenshots, policies,
  certifications, research methods, review profiles, or third-party pages.
- Unsupported marketing claims score low even if the copy is well written.

### Effort

- Score `5`: small copy, metadata, parity, or table edits.
- Score `3`: moderate page restructure or evidence collection.
- Score `1`: new asset production, engineering dependency, legal review, or
  third-party profile remediation.

### Confidence

- Score confidence from repeatability: multiple prompts, engines, logs, SERP
  checks, or source records.
- Lower confidence when the evidence is a single prompt run or an unstable
  daily answer snapshot.

### Freshness

- Require dates for pricing, product capabilities, local details, research
  samples, and comparison claims.
- Deprioritise stale facts until canonical values are refreshed.

### Third-party breadth

- Measure whether the same facts appear consistently across review platforms,
  directories, partner pages, profiles, citations, and independent references.
- Thin third-party coverage weakens GEO recommendations for PDP, SaaS feature,
  local, comparison, use-case, and research/report pages.

### Engine-specific mention and citation behaviour

Track each engine separately because retrieval, mention, and citation behaviour
diverge by product surface.

| Engine line | Record |
|-------------|--------|
| AIO | Query, date, location/device where relevant, cited URLs, mentioned brands, answer position, source IDs. |
| Gemini | Prompt, date, grounded/browsing state, citations, uncited mentions, source IDs. |
| ChatGPT | Prompt, date, browsing/search mode, citations or source links, brand mention context, source IDs. |
| AI Mode | Query, date, cited URLs, follow-up refinements, brand/entity mentions, source IDs. |
| Perplexity | Prompt, date, cited URLs, ranked source order, summary framing, source IDs. |

Reporting rule: never report aggregate AI Share of Voice without per-engine
lines. If a summary is required, show the aggregate only after the engine table
and state which engines and prompts contributed to it.

## Evidence Ledger Fields

| Field | Use |
|-------|-----|
| `source_id` | Stable ID used in recommendations, scorecards, and reports. |
| Source type | Page section, crawl record, SERP capture, engine run, third-party profile, log, review, policy, research data. |
| URL or path | Canonical source location when available. |
| Captured date | Date evidence was observed. |
| Claim supported | Specific recommendation or score dimension supported. |
| Confidence | High, medium, or low with reason. |
| Freshness risk | Expiry date or event that requires re-validation. |

## Priority Bands

| Weighted score | Band | Action |
|----------------|------|--------|
| 80-100 | P0 | Implement in the current sprint when evidence is strong and page value is high. |
| 60-79 | P1 | Plan next; batch with related page-type or evidence fixes. |
| 40-59 | P2 | Backlog unless needed to unblock P0/P1 work. |
| 0-39 | Watch | Monitor, collect evidence, or reject if page-type fit is poor. |
