---
description: Run end-to-end AI search readiness workflow across GEO, SRO, fan-out, consistency, and discoverability
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run AI search readiness workflow for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/ai-search-readiness.md`
2. Execute chained phases:
   - Fan-out decomposition
   - GEO criteria alignment
   - SRO snippet optimization
   - Hallucination defense
   - Agent discoverability validation
3. Return one prioritized backlog with readiness scorecard deltas

## Usage

```bash
# Full readiness cycle for a domain
/seo-ai-readiness example.com

# Full cycle for priority pages
/seo-ai-readiness "example.com /pricing /services/injury-law /about"
```

## Related

- `seo/ai-search-readiness.md`
- `commands/seo-fanout.md`
- `commands/seo-geo.md`
- `commands/seo-sro.md`
- `commands/seo-hallucination-defense.md`
- `commands/seo-agent-discovery.md`
- `seo/video-seo.md` — video readiness for LLM answer engine surfaces
