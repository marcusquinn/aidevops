---
description: Capture AI-search baseline metrics and produce a KPI scorecard using GEO, SRO, and discoverability diagnostics
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Create an AI-search baseline for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/ai-search-readiness.md`
2. Read `~/.aidevops/agents/seo/ai-search-kpi-template.md`
3. Run a baseline cycle across:
   - fan-out decomposition
   - GEO criteria coverage
   - SRO snippet assessment
   - hallucination defense audit
   - agent discoverability checks
4. Fill and return the KPI scorecard with baseline values and immediate priorities

## Usage

```bash
# Baseline for one domain
/seo-ai-baseline example.com

# Baseline for priority pages
/seo-ai-baseline "example.com /pricing /services/injury-law /about"
```

## Output

- Completed KPI scorecard
- Top 3 remediation priorities
- Re-test schedule recommendation

## Related

- `seo/ai-search-readiness.md`
- `seo/ai-search-kpi-template.md`
- `commands/seo-ai-readiness.md`
- `seo/video-seo.md` — include video AI surface metrics in baseline scorecard
