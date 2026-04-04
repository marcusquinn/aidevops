<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Search KPI Scorecard Template

Use one scorecard per AI-search cycle. Record baseline, current, delta,
target, and evidence for each material change.

## Cycle Metadata

- Project:
- Date:
- Owner:
- Scope (domain/pages):
- Intent clusters:
- Competitor set:

## KPI Snapshot

| KPI | Baseline | Current | Delta | Target | Notes |
|-----|----------|---------|-------|--------|-------|
| Grounding eligibility rate (%) | | | | | |
| Fan-out coverage (high-priority branches, %) | | | | | |
| Criteria coverage strong (%) | | | | | |
| Selection rate (cited/retrieved, %) | | | | | |
| Snippet fitness pass rate (%) | | | | | |
| Critical contradiction count | | | | | |
| Autonomous discovery success (%) | | | | | |
| Citation confidence (avg) | | | | | |
| Citation stability (variance) | | | | | |

## Diagnostic Evidence

| Area | Record |
|------|--------|
| Grounding eligibility | Queries tested; predicted-to-ground queries; confirmed grounded queries; key blockers |
| Fan-out and criteria gaps | Missing high-priority branches; partial branches; missing decision criteria |
| SRO and snippet findings | Low-survival sections; high-survival sections; sentence-level edits to test |
| Integrity and hallucination risk | Conflicting facts; unsupported claims; canonical source gaps |
| Agent discoverability | Task set used; completion failures; navigation/comprehension blockers |

## Prioritized Backlog

<!-- Add items as: 1. [ ] Description -->

## Re-test Plan

- Next run date:
- Intents to re-test:
- Pages changed since last run:
- Expected movement:
