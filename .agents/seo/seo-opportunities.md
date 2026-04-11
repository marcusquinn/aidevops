---
description: Export SEO data and analyze for ranking opportunities in one step
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run the complete SEO export + analysis workflow. Combines `/seo-export all` + `/seo-analyze`. Default range: 90 days.

Target: $ARGUMENTS

## Usage

```bash
/seo-opportunities example.com          # 90-day default
/seo-opportunities example.com --days 30
```

## Workflow

1. Parse `$ARGUMENTS` for domain and options.
2. Export all configured platforms: `~/.aidevops/agents/scripts/seo-export-helper.sh all $DOMAIN --days $DAYS`
3. Run full analysis: `~/.aidevops/agents/scripts/seo-analysis-helper.sh $DOMAIN`
4. Summarize: top 10 quick wins, top 10 striking-distance opportunities, low-CTR pages, content cannibalization issues.

## Outputs

```text
~/.aidevops/.agent-workspace/work/seo-data/{domain}/{platform}-{start}-{end}.toon
~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon
```

## Recommendation Order

1. **Quick Wins** — fastest ROI, minimal effort, on-page only
2. **Low CTR** — quick title/meta changes with traffic upside
3. **Cannibalization** — consolidate ranking signals before new work
4. **Striking Distance** — higher effort, higher upside

## Documentation

- Export details: `seo/data-export.md`
- Analysis details: `seo/ranking-opportunities.md`
