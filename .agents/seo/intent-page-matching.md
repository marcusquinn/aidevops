---
name: intent-page-matching
description: Match paid, organic, and buyer-question evidence to existing pages without publishing changes
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Intent-to-Page Matching

Use the offline matcher when paid search, organic query, or buyer-question evidence
needs a traceable existing-page fit decision. It proposes briefs only; it never
creates pages, changes ads, or claims a ranking or citation failure.

```bash
python3 .agents/scripts/intent-page-match-helper.py match \
  --input pages.json --decisions queries.json --dry-run
```

## Evidence contract

- Preserve each query's source passage, evidence state, and observed ranking URL.
  The observed URL is not a proposed destination.
- Require matching local rubric `id` and `version`; unknown or mismatched evidence
  abstains rather than being merged.
- Retrieval is bounded deterministic lexical matching. A missing candidate means
  only that this snapshot has insufficient evidence, not a search-engine defect.
- The report may yield one match, several equally supported pages, or an abstention.
  Inspect title/H1, answer text, offer and CTA evidence before acting on a result.
- Gap briefs deduplicate equivalent commercial intents and retain value, cost,
  sample, and lag uncertainty. They are non-mutating recommendations.

## Workflow handoffs

Normalize ambiguous conversational inputs with `conversational-search-intent.md`.
Use `query-fanout-research.md` for coverage analysis, and review offer/landing
congruence through `marketing-sales/ad-creative-offers-landing.md`. Do not treat
an ad-to-page disagreement as organic ranking evidence or a revenue promise.
