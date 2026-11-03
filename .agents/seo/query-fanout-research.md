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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Query Fan-Out Research

- **Purpose**: expose hidden sub-query themes behind one user intent
- **Inputs**: normalized intent packet, market context, existing page set, source IDs
- **Outputs**: fan-out map, priority tiers, coverage matrix, remediation backlog
- **Retrieval model**: broad discovery → domain deep-dive → third-party validation

## Workflow

**0) Normalize the seed** — when the input is conversational, ambiguous,
trend/news-led, or log-derived, use `conversational-search-intent.md` to preserve
the raw query and identify the user job, outcome, constraints, provenance, and
grounding hypothesis. If no observed evidence exists, label the seed as a
hypothesis.

**1) Build theme branches** — one core intent → 3-7 branches (selection criteria, trust, risk, alternatives, constraints). Each branch is a distinct retrieval objective.

**2) Generate sub-queries** — write sub-queries per branch with a purpose tag; assign priority (high/medium/low); include modifiers where relevant (location, budget, urgency, compliance, integration).

**3) Classify retrieval stage and scope** — frontier models generate 10+ sub-queries per prompt, including `site:` lookups. Treat fan-out as 3 stages:

1. **Broad discovery**: open-web category/comparison queries (e.g. `best ATS for SMB [year]`)
2. **Domain deep-dive**: `site:brand.com` queries (e.g. `site:brand.com pricing`)
3. **Third-party validation**: `site:g2.com`, `site:capterra.com`, `site:trustradius.com` — independent corroboration

| Scope | Meaning |
|-------|---------|
| **Open-web** | Model uncommitted to a domain; SERP ranking matters |
| **Domain-scoped** | Model extracting detail from a chosen domain; page architecture > SERP position |
| **Third-party** | Model seeking corroboration from review platforms |

Predict stages before content work: product-detail branches → stage 2; trust/risk branches → stage 3.

**4) Map coverage** — link each sub-query to the best existing page or proof source; mark coverage (complete/partial/missing); flag overloaded pages; branch is incomplete if your site covers it but review-platform evidence does not.

**5) Remediate and validate** — add concise sections for partial high-priority branches; create focused pages only for genuinely missing high-priority branches; add internal links mirroring fan-out relationships; re-run fan-out prompts and stage-specific retrieval checks; record match quality, citation mix changes, and unresolved branches for the next sprint.

## Coverage Rules

- Domain-scoped branches need individually addressable pages with self-contained answers (model queries your site like a database)
- Pages should match `site:yourdomain.com [category] [feature] [year]` patterns
- Third-party branches need current review-platform profiles with canonical facts matching the primary site

## Observed Fan-Out Capture (ChatGPT)

Use observed captures to corroborate modeled branches (steps 3 and 5) and to
supply the retrieval denominator for selection rate in
`ai-search-kpi-template.md`. The ChatGPT web app loads each conversation as JSON
from an internal, undocumented endpoint (`/backend-api/conversation/{id}`).
Message metadata in a web-search conversation holds three layers:

| Field | Contains | Use |
|-------|----------|-----|
| `search_model_queries` | Queries the model issued, grouped by `working_turn_id` | Observed sub-queries to compare with modeled branches |
| `search_result_groups` | Every retrieved result: title, URL, snippet, attribution, publication date | Retrieval denominator; the snippet text the model read |
| `content_references` | URLs cited in the answer | Citation numerator (match retrieved URLs after normalization) |

Capture and analysis rules:

- **Manual, own-account capture only** — read the response in browser DevTools
  or with a reviewed client-side userscript from your signed-in session. Do not
  script requests against the endpoint or share session tokens. The endpoint and
  field names are unofficial; re-check them before each capture batch.
- **Turn, not query, attribution** — one search turn can issue several queries
  and return one merged result pool. Never attribute a result to a specific
  query; report results per turn alongside that turn's query set.
- **Active branch only** — conversations are a tree (`mapping` plus
  `current_node`); regenerated or edited replies leave off-branch results.
  Count the active branch by default and flag any regenerated results you keep.
- **Citation is a proxy for use** — the data has no separate "read" signal.
- **Source-type mix** — bucket retrieved domains (owned, review platform,
  directory, maps, Reddit, YouTube, other social) and report retrieval and
  citation share per bucket. A high third-party share means stage 3 validation
  drives the category, so listings and profiles may matter more than new pages.
- **Snippet review** — the retrieved snippet for your own pages is the text the
  model worked with; weak snippets usually trace to weak page intros or meta
  descriptions (see `sro-grounding.md`).
- **Sample, don't anecdote** — results vary by account, location, time, and
  model routing. Record the model slug and capture date, and repeat across the
  prompt cohort before drawing conclusions.
- **Phrase frequency is a hypothesis** — terms that over-index in cited versus
  uncited snippets are small-sample correlation; use them to choose copy tests,
  never as a KPI.
- **Referral tagging** — note whether cited URLs carry `utm_source=chatgpt`;
  it helps match ChatGPT referrals in analytics.

Observed queries show what the model searched, not what users search: they
corroborate branches but are not demand metrics.

## Guardrails

- Optimize for thematic completeness, not maximal query count
- Keep generated branches separate from observed demand until corroborated by
  search metrics, first-party language, or other dated evidence
- Avoid duplicate pages for near-identical branches
- Keep branch language aligned with real user phrasing
- Re-baseline when SERP intent or product positioning changes

## Related Subagents

- `conversational-search-intent.md` — normalize intent and preserve provenance
- `geo-strategy.md` — criteria-led optimization strategy
- `sro-grounding.md` — snippet and selection tuning
- `keyword-mapper.md` — keyword-to-section placement
