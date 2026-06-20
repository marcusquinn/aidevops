---
description: Google Alerts-style direct-source coverage tracking with local state
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Coverage Tracker

Track whether configured keywords appeared in real coverage. This answers “did we get mentioned?” not “what can we newsjack?”

## Config shape

```json
{
  "name": "Example Brand",
  "lookback_days": 2,
  "keywords": [
    {
      "keyword": "example brand",
      "means": "Example Brand, the B2B analytics company",
      "exclude_hints": ["generic phrase uses"]
    }
  ]
}
```

## Run workflow

1. For each keyword, run `news-search.md` with a recency bound.
2. Dedupe canonical URLs and same-article syndication.
3. Classify: `real_coverage`, `wrong_entity`, `press_release_only`, `syndicated_pickup`, `low_quality`, `unknown`.
4. Compare against local seen-state if available; otherwise disclose no repeat suppression.
5. Return new real coverage and filtered counts.

## Routine fit

Use `public-relations/routines.md` plus `workflows/routine.md` for daily or weekly checks. Keep deterministic collection separate from PR interpretation.
