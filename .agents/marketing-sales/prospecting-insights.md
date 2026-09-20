---
name: prospecting-insights
description: Evidence-linked, offline competitor and pain-theme summaries
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Prospecting Insights

Derive project-local snapshots from supplied, authorized observations and reviewed
decisions only. Every summary retains source IDs, thread boundaries, dates, access
scope, spans, and evidence digests. Counts are coverage-bound observations, not
customers, market share, demand, or a recommendation to contact anyone.

```bash
python3 .agents/scripts/prospecting-insights-helper.py derive \
  --input INPUT.json --decisions DECISIONS.json --dry-run

python3 .agents/scripts/prospecting-insights-helper.py compare \
  --baseline BASELINE.json --current CURRENT.json --dry-run
```

Unknown, partial, failed, ambiguous, and quoted classifications remain explicit.
Quoted criticism is not attributed to the author. Replayed source IDs are deduped;
edited evidence must receive a new source ID. The helper only emits a derived,
non-mutating report: it never profiles users, changes targeting, contacts prospects,
trains models, or rewrites raw evidence or manual dispositions. Cross-window
comparisons require a supplied compatible baseline with the same rubric; otherwise
the report states that comparison is unavailable.
