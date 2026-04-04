---
description: Test AI agent discoverability across multi-turn browsing tasks
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run AI agent discoverability diagnostics for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/ai-agent-discovery.md`
2. Define broad and goal-focused discovery tasks
3. Classify failures (missing content vs discoverability vs comprehension)
4. Produce remediation steps and re-test scorecard

## Usage

```bash
# Discoverability diagnostics for a domain
/seo-agent-discovery example.com

# Diagnostics for specific user tasks
/seo-agent-discovery "example.com pricing enterprise support response time"
```

## Related

- `seo/ai-agent-discovery.md`
- `commands/seo-hallucination-defense.md`
- `commands/seo-ai-readiness.md`
