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

**Quick Commands**:

```bash
# Full analysis
seo-analysis-helper.sh example.com

# Specific analyses
seo-analysis-helper.sh example.com quick-wins
seo-analysis-helper.sh example.com striking-distance
seo-analysis-helper.sh example.com low-ctr
seo-analysis-helper.sh example.com cannibalization

# View data summary
seo-analysis-helper.sh example.com summary
```

<!-- AI-CONTEXT-END -->

## Analysis Types

### Quick Wins

**Criteria**: Position 4-20, Impressions > 100

Keywords already ranking on page 1-2 that could move higher with small improvements.

**Actions**:
- Optimize title tags and meta descriptions
- Add internal links from high-authority pages
- Improve content depth and relevance
- Add schema markup

**Scoring**: Higher impressions + closer to position 4 = higher score

### Striking Distance

**Criteria**: Position 11-30, Volume > 500

Keywords just off page 1 with significant search volume. Moving these to page 1 can drive substantial traffic.

**Actions**:
- Expand content significantly
- Build quality backlinks
- Improve page speed and Core Web Vitals
- Add supporting content (topic clusters)

**Scoring**: Volume × (31 - position) = opportunity score

### Low CTR

**Criteria**: CTR < 2%, Impressions > 500, Position ≤ 10

Keywords ranking well but not getting clicks. Usually indicates poor title/meta or SERP feature competition.

**Actions**:
- Rewrite title tags to be more compelling
- Improve meta descriptions with CTAs
- Add structured data for rich snippets
- Check for SERP feature opportunities (FAQ, How-to)

**Potential**: Calculated as impressions × 5% (target CTR)

### Content Cannibalization

**Criteria**: Same query ranking with multiple URLs

Multiple pages competing for the same keyword, diluting ranking signals.

**Actions**:
- Merge content into a single authoritative page
- Add canonical tags to secondary pages
- Differentiate content focus (different intent)
- Use 301 redirects if merging

**Detection**: Groups queries by normalized text, identifies those with 2+ unique URLs

## Output Format

Analysis results are saved in TOON format:

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

### 1. Export Data

```bash
# Export from all configured platforms
seo-export-helper.sh all example.com --days 90
```

### 2. Run Analysis

```bash
# Full analysis
seo-analysis-helper.sh example.com
```

### 3. Review Results

```bash
# View the analysis file
cat ~/.aidevops/.agent-workspace/work/seo-data/example.com/analysis-*.toon
```

### 4. Take Action

Prioritize by:
1. **Quick wins** - Fastest ROI, minimal effort
2. **Low CTR** - Title/meta changes are quick
3. **Cannibalization** - Prevents wasted effort
4. **Striking distance** - Longer-term, higher effort

## Thresholds

Default thresholds can be adjusted in the script:

| Analysis | Parameter | Default |
|----------|-----------|---------|
| Quick Wins | Min Position | 4 |
| Quick Wins | Max Position | 20 |
| Quick Wins | Min Impressions | 100 |
| Striking Distance | Min Position | 11 |
| Striking Distance | Max Position | 30 |
| Striking Distance | Min Volume | 500 |
| Low CTR | Max CTR | 0.02 (2%) |
| Low CTR | Min Impressions | 500 |

## Multi-Source Analysis

The analysis combines data from all available sources:
- GSC provides actual click/impression data
- Ahrefs/DataForSEO provide volume and difficulty
- Bing provides additional search engine coverage

When the same query appears in multiple sources, all instances are considered for cannibalization detection.

## Example Output

```text
=== Quick Wins Analysis ===
[INFO] Criteria: Position 4-20, Impressions > 100

[SUCCESS] Found 47 quick win opportunities

Top 10 Quick Wins:
Query | Position | Impressions | Source
------|----------|-------------|-------
best seo tools 2026                      | 6.2 | 4500 | gsc
keyword research guide                   | 8.1 | 3200 | gsc
how to improve seo                       | 11.3 | 2800 | gsc

=== Content Cannibalization Analysis ===
[INFO] Finding queries with multiple ranking URLs

[SUCCESS] Found 12 cannibalized queries

Top 10 Cannibalized Queries:
Query | # Pages | Positions
------|---------|----------
seo tools                                | 3 | 6.2,15.3,28.1
keyword research                         | 2 | 8.1,22.4
```

## Integration

### With Keyword Research

```bash
# Find opportunities, then research related keywords
seo-analysis-helper.sh example.com quick-wins
/keyword-research-extended "top opportunity keyword"
```

### With Content Planning

Use analysis results to prioritize content updates:
1. Quick wins → Update existing content
2. Striking distance → Expand content
3. Cannibalization → Consolidate pages

### With Reporting

Export analysis for stakeholder reports:

```bash
# Convert TOON to CSV for spreadsheets
cat analysis-*.toon | awk -F'\t' 'NF>1{print}' > analysis.csv
```
