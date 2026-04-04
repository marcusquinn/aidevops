---
description: Audit and reduce AI brand hallucination risk from inconsistent or unsupported site content
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run hallucination defense for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/ai-hallucination-defense.md`
2. Build critical fact inventory and canonical source map
3. Find contradictory values and unsupported claims
4. Output prioritized remediation plan and re-test prompt set

## Usage

```bash
# Full consistency and claim audit
/seo-hallucination-defense example.com

# Focused audit for key conversion pages
/seo-hallucination-defense "example.com /pricing /about /services/injury-law"
```

## Related

- `seo/ai-hallucination-defense.md`
- `commands/seo-agent-discovery.md`
- `commands/seo-ai-readiness.md`
