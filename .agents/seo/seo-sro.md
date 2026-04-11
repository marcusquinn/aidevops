---
description: Run Selection Rate Optimization workflow for grounding snippets
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run SRO grounding optimization for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/sro-grounding.md`
2. Baseline snippet extraction behavior for representative intents
3. Identify sentence-level and structure-level improvements
4. Produce a controlled re-test plan with expected SRO deltas

## Usage

```bash
# SRO workflow for a domain
/seo-sro example.com

# SRO workflow for key pages
/seo-sro "example.com /pricing /services/injury-law"
```

## Related

- `seo/sro-grounding.md`
- `commands/seo-geo.md`
- `commands/seo-fanout.md`
