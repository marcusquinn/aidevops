---
description: Analyze SEO data for ranking opportunities and content issues
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SEO Ranking Opportunities

<!-- AI-CONTEXT-START -->
- **Commands**: `/seo-analyze`, `/seo-opportunities`, `seo-analysis-helper.sh`
- `seo-analysis-helper.sh example.com [quick-wins|striking-distance|low-ctr|cannibalization|summary]`
<!-- AI-CONTEXT-END -->

## Workflow

1. **Export**: `seo-export-helper.sh all example.com --days 90`
2. **Analyze**: `seo-analysis-helper.sh example.com`
3. **Review**: `~/.aidevops/.agent-workspace/work/seo-data/example.com/analysis-*.toon`
4. **Prioritize**: Quick wins → Low CTR → Cannibalization → Striking distance
5. **Extend**: `seo-analysis-helper.sh example.com quick-wins` → `/keyword-research-extended "top opportunity keyword"`

Data sources: GSC (clicks/impr), Ahrefs/DataForSEO (volume/difficulty), Bing — merged across sources; cannibalization detection spans all.

## Analysis Types

| Type | Criteria | Actions | Scoring |
|------|----------|---------|---------|
| **Quick Wins** | Position 4–20, Impressions > 100 | Optimize title/meta, internal links, content depth, schema | Impressions + proximity to Position 4 |
| **Striking Distance** | Position 11–30, Volume > 500 | Expand content, backlinks, CWV, topic clusters | `volume × (31 - position)` |
| **Low CTR** | CTR < 2%, Impressions > 500, Position ≤ 10 | Rewrite title/meta, CTAs, structured data, SERP features | Potential: `impressions × 5%` |
| **Cannibalization** | Multiple URLs per query | Merge pages, canonicals, differentiate intent, 301s | Groups by query; flags 2+ URLs |

## Output Format (TOON)

```text
domain	example.com
type	analysis
analyzed	2026-01-28T10:30:00Z
---
# Quick Wins
query	page	impressions	position	score	source
best seo tools	/blog/seo-tools	5000	8.2	85	gsc
---
# Striking Distance
query	page	volume	position	score	source
keyword research	/guides/keywords	2400	12.4	44640	ahrefs
---
# Low CTR Opportunities
query	page	impressions	ctr	position	potential_clicks	source
seo tips	/blog/tips	3000	0.015	5	150	gsc
---
# Content Cannibalization
query	pages	positions	page_count
seo tools	/blog/tools,/guides/seo	8.2,15.3	2
```
