---
name: geo-strategy
description: Build AI search visibility strategies by extracting decision criteria and closing retrieval gaps on high-value pages
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

# GEO Strategy

Increase citation likelihood in AI search by matching decision criteria with verifiable page content on pages that already rank. Ranking is prerequisite — unranked pages cannot be consistently cited. Optimize for deterministic retrieval signals, not daily answer volatility.

**Inputs:** core query set, top landing pages, competitor set, proof assets (certifications, policies, prices, case evidence)
**Outputs:** criteria matrix, page gap map, prioritized implementation plan

## Workflow

### 1) Scope high-value intents

- Select 5-20 intents that influence revenue or lead quality; map each to an existing target page
- Exclude intents without a realistic ranking path
- Classify by grounding likelihood to avoid optimizing non-retrieval prompts

### 2) Extract decision criteria

- Probe multiple models with targeted buying-decision prompts
- Normalize into concrete criteria (not vague advice); cluster by: trust, expertise, fit, cost, delivery, risk

### 3) Score coverage per page

- Mark each criterion: strong, partial, missing, or not applicable
- Require evidence references (URL section, data source, policy, certification)
- Flag unsupported marketing claims immediately

### 4) Build retrieval-ready summaries

- Add a concise criteria-matching block near top of page
- Keep claims specific, self-contained, and fact-backed — not broad brand language

### 5) Validate and iterate

- Re-check retrieval fitness after edits; evaluate coverage before citation counts
- Monitor citations directionally, not as the only success metric
- Re-run criteria extraction monthly or after major model shifts

## Anti-Patterns

- Prompt-rank dashboards without content remediation
- Large batches of AI-generated pages with weak evidence
- Generic "best" claims without supporting proof
- Treating one model's output snapshot as durable ground truth

## Implementation Rules

- First 200-300 words must be criteria-dense and informative
- Use explicit headings for key buyer concerns; align terminology with user query vocabulary
- Single canonical value for every critical fact across the site
- Prefer additive edits to existing pages before creating net-new pages
- Keep key pages accessible to major AI/search crawlers
- One topic per URL; titles, H1s, and headings must include category terms, feature type, year, and pricing where applicable
- Keep pricing, feature lists, and comparison data in crawlable HTML — not behind JS rendering or gated forms
- AI models use `site:yourdomain.com [category] features [year]` patterns to extract detail from known-relevant domains

### Review platform parity

AI models query G2, Capterra, and TrustRadius as a validation stage after extracting brand-site claims:

- Maintain complete profiles with the same canonical facts (pricing, features, integrations) as the primary site
- Consistent product naming across platforms; wrong category = invisible to model queries
- Respond to reviews — AI models may extract vendor responses as support quality evidence
- Monitor profiles quarterly; add TrustRadius, PeerSpot, or vertical-specific sites where G2/Capterra coverage is thin

## Related Subagents

- `sro-grounding.md` for snippet selection and grounding optimization
- `query-fanout-research.md` for sub-query and theme decomposition
- `ai-hallucination-defense.md` for contradiction and claim-evidence audits
- `keyword-research.md` for demand and intent validation
