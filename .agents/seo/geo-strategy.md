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

# GEO Strategy

Design and evaluate AI search optimization strategy with a retrieval-first approach.

## Quick Reference

- Purpose: increase citation likelihood in AI search by matching decision criteria with verifiable page content
- Primary outcome: better AI retrieval fit on pages that already rank in traditional search
- Inputs: core query set, top landing pages, competitor set, proof assets (certifications, policies, prices, case evidence)
- Outputs: criteria matrix, page gap map, prioritized implementation plan

## Positioning

- Use GEO as an operational label, not a replacement for SEO
- Treat ranking as prerequisite: if page does not rank, it cannot be consistently cited
- Optimize for deterministic retrieval signals, not daily answer volatility

## Workflow

### 1) Scope high-value intents

- Select 5-20 intents that influence revenue or lead quality
- Map each intent to an existing target page
- Exclude intents without a realistic ranking path yet
- Classify intents by grounding likelihood to avoid optimizing non-retrieval prompts

### 2) Extract decision criteria

- Probe multiple models with targeted buying-decision prompts
- Normalize outputs into concrete criteria (not vague advice)
- Cluster by category: trust, expertise, fit, cost, delivery, risk

### 3) Score coverage per page

- For each criterion, mark page state: strong, partial, missing, not applicable
- Require evidence references (URL section, data source, policy, certification)
- Flag unsupported marketing claims immediately

### 4) Build retrieval-ready summaries

- Add a concise criteria-matching block near top of page
- Keep claims specific and self-contained
- Prefer facts with provenance over broad brand language

### 5) Validate and iterate

- Re-check retrieval fitness after edits
- Monitor citations directionally, but evaluate by coverage and consistency first
- Re-run criteria extraction monthly or after major model shifts
- Watch citation confidence and volatility, not only mention count

## Implementation Rules

- Keep the first 200-300 words highly informative and criteria-dense
- Use explicit headings for key buyer concerns
- Keep terminology aligned with user query vocabulary and synonyms
- Keep a single canonical value for every critical fact across the site
- Prefer additive edits to existing pages before creating net-new pages
- Ensure key pages remain accessible to major AI/search crawlers
- Build site-searchable content architecture: important product pages should
  rank for internal domain retrieval patterns like
  `site:yourdomain.com [category] features [year]`
- Keep high-intent terms in title, H1, and section headings so domain-scoped
  retrieval can match quickly without deep crawl depth
- Maintain review platform parity (G2/Capterra/TrustRadius): keep pricing,
  feature limits, target segment, and support model aligned with canonical site
- Track outbound citations from profile links and comparison assets with
  UTM conventions so third-party mention flow can be attributed

### Site-searchable content architecture

AI models use `site:yourdomain.com` queries to extract detail from domains they have already identified as relevant. This bypasses traditional SERP ranking — the model is searching your site directly. Content must be structured for domain-scoped retrieval:

- Key product/feature pages must return relevant results for `site:yourdomain.com [category] features [year]` query patterns
- Each major product, feature, or service should have a dedicated page with a descriptive title containing category terms (not just brand names)
- Page titles and H1s should include the terms an AI model would use in a `site:` query: product category, feature type, year, and pricing where applicable
- Avoid consolidating all product information into a single page — domain-scoped search works best when each topic has its own addressable URL
- Ensure pricing, feature lists, and comparison data are in crawlable HTML, not locked behind JavaScript rendering or gated forms

### Third-party review platform strategy

AI models use `site:g2.com`, `site:capterra.com`, and `site:trustradius.com` queries as a validation stage after extracting claims from brand sites. Third-party citations serve as independent confirmation:

- Maintain complete, current profiles on G2, Capterra, and TrustRadius with the same canonical facts (pricing, features, integrations) as the primary site
- Ensure review platform profiles use consistent product naming and categorization
- Respond to reviews to demonstrate active engagement (AI models may extract vendor responses as evidence of support quality)
- Keep category listings accurate — if the model searches `site:g2.com [your brand] [wrong category]`, it finds nothing
- Monitor review platform profiles quarterly to ensure feature lists and pricing reflect current offerings
- Consider TrustRadius, PeerSpot, and vertical-specific review sites for B2B categories where G2/Capterra coverage is thin

## Anti-Patterns

- Prompt-rank dashboards without content remediation
- Large batches of AI-generated pages with weak evidence
- Generic "best" claims without supporting proof
- Treating one model's output snapshot as durable ground truth

## Related Subagents

- `sro-grounding.md` for snippet selection and grounding optimization
- `query-fanout-research.md` for sub-query and theme decomposition
- `ai-hallucination-defense.md` for contradiction and claim-evidence audits
- `keyword-research.md` for demand and intent validation
