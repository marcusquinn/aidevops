---
name: ai-agent-discovery
description: Verify autonomous AI agents can locate and understand critical site information via multi-turn exploration
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

# AI Agent Discovery

Verify agents can find, interpret, and trust key business information. Outputs: discoverability report, gap classification, remediation backlog.

## Workflow

1. **Define tasks** — select 5–15 user goals (pricing, eligibility, integration, support, compliance); include broad and goal-focused scenarios
2. **Simulate exploration** — capture search attempts, page hits, confidence changes; note loops/backtracks/stalls; separate retrieval failure from comprehension failure
   - First-party: `site:yourdomain.com pricing`, `site:yourdomain.com integrations`
   - Third-party: `site:g2.com [brand]`, `site:capterra.com [brand]` — compare fact consistency
3. **Classify findings** — clearly found / found but partial / not found (discoverability issue) / not found (content gap)
4. **Fix by failure type**
   - Discoverability: improve wording, headings, internal linking
   - Content gap: add concise, evidence-backed section or dedicated page
   - Comprehension: rewrite for standalone clarity
5. **Re-run and score** — re-test same tasks; track completion rate and turn count reduction; promote fixes that improve both human and agent outcomes

## Common Discoverability Problems

- Critical facts trapped in PDFs or images without text equivalents
- Internal jargon instead of user vocabulary; key answers scattered across weakly-linked pages
- High-value pages lack explicit sections for common decision questions
- Page titles use brand-centric language that doesn't match `site:` query patterns (e.g., "Our Solution" vs "[Category] Software Features")
- Review platform profiles outdated — third-party validation returns stale data
- Key product pages consolidated into one URL — domain-scoped search returns one page for all queries

## Related Subagents

- `query-fanout-research.md` — thematic query planning
- `ai-hallucination-defense.md` — factual consistency and claim hygiene
- `site-crawler.md` — structure and linking audits
