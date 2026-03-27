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

- **Purpose**: Analyze exported SEO data for actionable ranking opportunities
- **Input**: TOON files from `seo-export-helper.sh`
- **Output**: Analysis report in TOON format
- **Commands**: `/seo-analyze`, `/seo-opportunities`, `seo-analysis-helper.sh`

```bash
seo-analysis-helper.sh example.com                    # Full analysis
seo-analysis-helper.sh example.com quick-wins         # Quick wins only
seo-analysis-helper.sh example.com striking-distance  # Striking distance
seo-analysis-helper.sh example.com low-ctr            # Low CTR
seo-analysis-helper.sh example.com cannibalization    # Cannibalization
seo-analysis-helper.sh example.com summary            # Data summary
```

<!-- AI-CONTEXT-END -->

## Analysis Types

### Quick Wins
**Criteria**: Position 4–20, Impressions > 100 — page 1–2 keywords that could rank higher with small improvements.

**Actions**: Optimize title/meta, add internal links from high-authority pages, improve content depth, add schema markup.

**Scoring**: Higher impressions + closer to position 4 = higher score.

### Striking Distance
**Criteria**: Position 11–30, Volume > 500 — keywords just off page 1 with significant volume.

**Actions**: Expand content, build backlinks, improve Core Web Vitals, add topic cluster support.

**Scoring**: `volume × (31 - position)`

### Low CTR
**Criteria**: CTR < 2%, Impressions > 500, Position ≤ 10 — ranking well but not getting clicks.

**Actions**: Rewrite title tags, improve meta descriptions with CTAs, add structured data, check SERP feature opportunities (FAQ, How-to).

**Potential**: `impressions × 5%` (target CTR)

### Content Cannibalization
**Criteria**: Same query ranking with multiple URLs — dilutes ranking signals.

**Actions**: Merge into single authoritative page, add canonicals to secondary pages, differentiate intent, use 301 redirects.

**Detection**: Groups queries by normalized text; flags those with 2+ unique URLs.

## Thresholds

| Analysis | Parameter | Default |
|----------|-----------|---------|
| Quick Wins | Position range | 4–20 |
| Quick Wins | Min Impressions | 100 |
| Striking Distance | Position range | 11–30 |
| Striking Distance | Min Volume | 500 |
| Low CTR | Max CTR | 0.02 (2%) |
| Low CTR | Min Impressions | 500 |

## Output Format

```text
domain	example.com
type	analysis
analyzed	2026-01-28T10:30:00Z
sources	4
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

## Workflow

1. **Export**: `seo-export-helper.sh all example.com --days 90`
2. **Analyze**: `seo-analysis-helper.sh example.com`
3. **Review**: `cat ~/.aidevops/.agent-workspace/work/seo-data/example.com/analysis-*.toon`
4. **Prioritize**: Quick wins → Low CTR → Cannibalization → Striking distance

## Multi-Source

GSC provides click/impression data; Ahrefs/DataForSEO provide volume and difficulty; Bing provides additional coverage. When the same query appears in multiple sources, all instances are considered for cannibalization detection.

## Integration

```bash
# Find opportunities, then research related keywords
seo-analysis-helper.sh example.com quick-wins
/keyword-research-extended "top opportunity keyword"

# Export TOON to CSV for stakeholder reports
cat analysis-*.toon | awk -F'\t' 'NF>1{print}' > analysis.csv
```

Use analysis results to prioritize content work: quick wins → update existing content; striking distance → expand content; cannibalization → consolidate pages.
