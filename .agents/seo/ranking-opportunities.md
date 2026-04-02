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

# SEO Ranking Opportunities

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Analyze exported SEO data for ranking opportunities
- **Input**: TOON files from `seo-export-helper.sh`
- **Output**: Analysis report in TOON format
- **Commands**: `/seo-analyze`, `/seo-opportunities`, `seo-analysis-helper.sh`

```bash
seo-analysis-helper.sh example.com [quick-wins|striking-distance|low-ctr|cannibalization|summary]
```

<!-- AI-CONTEXT-END -->

## Workflow

1. **Export**: `seo-export-helper.sh all example.com --days 90`
2. **Analyze**: `seo-analysis-helper.sh example.com`
3. **Review**: `cat ~/.aidevops/.agent-workspace/work/seo-data/example.com/analysis-*.toon`
4. **Prioritize**: Quick wins → Low CTR → Cannibalization → Striking distance

## Analysis Types

| Type | Criteria | Actions | Scoring |
|------|----------|---------|---------|
| **Quick Wins** | Pos 4–20, Impr > 100 | Optimize title/meta, internal links, content depth, schema | Impr + proximity to Pos 4 |
| **Striking Distance** | Pos 11–30, Vol > 500 | Expand content, backlinks, CWV, topic clusters | `volume × (31 - position)` |
| **Low CTR** | CTR < 2%, Impr > 500, Pos ≤ 10 | Rewrite title/meta, CTAs, structured data, SERP features | Potential: `impr × 5%` |
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
```

## Multi-Source

GSC (clicks/impr), Ahrefs/DataForSEO (volume/difficulty), and Bing data are merged. Queries across sources are considered for cannibalization detection.

## Integration

```bash
# Find opportunities, then research related keywords
seo-analysis-helper.sh example.com quick-wins
/keyword-research-extended "top opportunity keyword"
```

Prioritize: quick wins (update) → striking distance (expand) → cannibalization (consolidate).
