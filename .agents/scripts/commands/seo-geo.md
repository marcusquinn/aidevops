---
description: Run GEO strategy workflow for AI search visibility
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run GEO strategy for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/geo-strategy.md`
2. Build criteria coverage matrix for target intents/pages
3. Identify strong/partial/missing criteria with evidence references
4. Produce prioritized implementation plan for retrieval-first improvements

## Usage

```bash
# GEO strategy for a domain
/seo-geo example.com

# GEO strategy for specific page set
/seo-geo "example.com /services/injury-law /services/work-accident"
```

## Related

- `seo/geo-strategy.md`
- `commands/seo-sro.md`
- `commands/seo-fanout.md`
