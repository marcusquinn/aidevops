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

```bash
seo-export-helper.sh all example.com --days 90   # export first
seo-analysis-helper.sh example.com               # full analysis
seo-analysis-helper.sh example.com quick-wins    # targeted
seo-analysis-helper.sh example.com striking-distance
seo-analysis-helper.sh example.com low-ctr
seo-analysis-helper.sh example.com cannibalization
seo-analysis-helper.sh example.com summary
```

<!-- AI-CONTEXT-END -->

## Analysis Types

### Quick Wins
**Criteria**: Position 4-20, Impressions > 100. Keywords on page 1-2 that could rank higher with small improvements.

**Actions**: Optimize title/meta, add internal links from high-authority pages, improve content depth, add schema markup.

**Scoring**: Higher impressions + closer to position 4 = higher score.

### Striking Distance
**Criteria**: Position 11-30, Volume > 500. Keywords just off page 1 with significant search volume.

**Actions**: Expand content, build quality backlinks, improve Core Web Vitals, add topic cluster content.

**Scoring**: Volume × (31 − position) = opportunity score.

### Low CTR
**Criteria**: CTR < 2%, Impressions > 500, Position ≤ 10. Ranking well but not getting clicks — usually poor title/meta or SERP feature competition.

**Actions**: Rewrite titles to be compelling, improve meta descriptions with CTAs, add structured data, check FAQ/How-to SERP features.

**Potential**: impressions × 5% (target CTR).

### Content Cannibalization
**Criteria**: Same query ranking with multiple URLs. Multiple pages diluting ranking signals.

**Actions**: Merge into a single authoritative page, add canonical tags, differentiate content intent, use 301 redirects when merging.

**Detection**: Groups queries by normalized text; flags those with 2+ unique URLs.

## Thresholds

| Analysis | Parameter | Default |
|----------|-----------|---------|
| Quick Wins | Position range | 4–20 |
| Quick Wins | Min Impressions | 100 |
| Striking Distance | Position range | 11–30 |
| Striking Distance | Min Volume | 500 |
| Low CTR | Max CTR | 2% |
| Low CTR | Min Impressions | 500 |

## Output Format

Results saved as TOON:

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

## Prioritization

Work in this order for best ROI:
1. **Quick wins** — fastest ROI, minimal effort
2. **Low CTR** — title/meta changes are quick
3. **Cannibalization** — prevents wasted effort
4. **Striking distance** — longer-term, higher effort

## Integration

```bash
# Research top opportunity keyword
seo-analysis-helper.sh example.com quick-wins
/keyword-research-extended "top opportunity keyword"

# Export for stakeholder reports
cat analysis-*.toon | awk -F'\t' 'NF>1{print}' > analysis.csv
```

Data sources: GSC (actual click/impression data), Ahrefs/DataForSEO (volume + difficulty), Bing (additional coverage). When the same query appears in multiple sources, all instances are considered for cannibalization detection.
