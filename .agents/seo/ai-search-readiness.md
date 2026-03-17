---
name: ai-search-readiness
description: "Orchestrate end-to-end AI search readiness across seven phases: grounding eligibility, query decomposition, criteria alignment (GEO), snippet survivability (SRO), integrity hardening, autonomous discoverability, and citation monitoring."
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

# AI Search Readiness

Run a complete, high-signal workflow to improve AI search citations and answer quality.

## Quick Reference

- Purpose: execute a repeatable end-to-end readiness cycle
- Inputs: target intents, priority pages, fact inventory, competitor set
- Outputs: prioritized fixes with measurable readiness deltas
- Scorecard template: `seo/ai-search-kpi-template.md`
- Cadence: monthly baseline, then sprint-level re-tests after content changes

## Execution Sequence

### Phase 0: Grounding eligibility gate

- Classify target queries by likelihood of triggering search grounding
- Prioritize intents where retrieval can be influenced by SEO changes
- Validate crawler/bot accessibility so eligible queries can actually fetch content
- Run site-query readiness checks for critical claims:
  `site:yourdomain.com [product category] features`,
  `site:yourdomain.com pricing`,
  `site:yourdomain.com integrations`

### Phase 1: Query decomposition

- Use `query-fanout-research.md`
- Outcome: thematic branches and sub-query map per intent

### Phase 2: Criteria alignment

- Use `geo-strategy.md`
- Outcome: criteria matrix and page-level strong/partial/missing coverage map

### Phase 3: Snippet survivability

- Use `sro-grounding.md`
- Outcome: top-of-page and sentence-level changes that improve selection likelihood

### Phase 4: Integrity hardening

- Use `ai-hallucination-defense.md`
- Outcome: contradiction fixes, claim-evidence alignment, canonical fact hygiene

### Phase 5: Autonomous discoverability

- Use `ai-agent-discovery.md`
- Outcome: task-completion diagnostics and discoverability gap remediation

### Phase 6: Citation and volatility monitoring

- Track citation frequency and confidence by intent cluster
- Monitor volatility and re-run high-impact intents on schedule
- Keep a rolling benchmark so wins are distinguished from noise
- Audit third-party citation readiness quarterly: verify G2/Capterra/
  TrustRadius profiles are current and fact-aligned with canonical site pages
- Use UTM-tagged profile links and partner citations so citation-driven
  sessions and conversion contribution are measurable

## Readiness Scorecard (Recommended)

- Fan-out coverage: percent of high-priority branches fully covered
- Grounding eligibility: percent of target intents likely to trigger retrieval
- Criteria coverage: percent of required criteria marked strong
- Snippet fitness: percent of intents with high-quality selected snippets
- Fact integrity: count of critical contradictions unresolved
- Discovery success: percent of tasks completed by autonomous exploration
- Citation stability: variance in citation frequency over repeated runs
- Site-query readiness: percent of priority pages retrievable via `site:yourdomain.com [category]` queries
- Third-party profile currency: percent of review platform profiles updated within the last 90 days

## Prioritization Rules

- Fix critical fact contradictions before expanding content
- Prioritize pages that already rank and convert
- Prefer focused section updates before creating new URLs
- Keep evidence traceable for every important claim
- Re-validate key pages after major model updates or indexing shifts

## Related Subagents

- `query-fanout-research.md`
- `geo-strategy.md`
- `sro-grounding.md`
- `ai-hallucination-defense.md`
- `ai-agent-discovery.md`
