---
description: Review-only content lifecycle proposals, redirect candidates, and visible structured-data consistency
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Content Disposition

Use the offline helper to propose `keep`, `update`, `merge`, `remove`, or `abstain` from bounded crawl and demand evidence. It never changes redirects, canonicals, noindex directives, page content, or publication state.

```bash
python3 .agents/scripts/seo-content-disposition-helper.py review --input pages.json --decisions decisions.json --dry-run
```

The report separates measured demand from missing evidence, protects designated revenue/legal/service pages, and only suggests a migration map when a live `200` target has matching intent. Missing targets, loops, chains, and many-to-one decisions require review rather than mutation.

Structured-data findings are distinct: syntax validity, visible-content consistency, and factual verification. A visible claim may still be factually unresolved.
