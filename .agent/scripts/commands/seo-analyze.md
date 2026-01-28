---
description: Analyze exported SEO data for ranking opportunities
agent: SEO
mode: subagent
---

Analyze exported SEO data for ranking opportunities, content cannibalization, and optimization targets.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Find actionable SEO opportunities
- **Input**: TOON files from `/seo-export`
- **Output**: Analysis report in TOON format

## Usage

```bash
# Full analysis
/seo-analyze example.com

# Specific analyses
/seo-analyze example.com quick-wins
/seo-analyze example.com striking-distance
/seo-analyze example.com low-ctr
/seo-analyze example.com cannibalization

# View data summary
/seo-analyze example.com summary
```

## Process

1. Parse $ARGUMENTS to extract domain and analysis type
2. Run the analysis script:

```bash
~/.aidevops/agents/scripts/seo-analysis-helper.sh $ARGUMENTS
```

3. Present results with actionable recommendations

## Analysis Types

| Type | Criteria | Action |
|------|----------|--------|
| Quick Wins | Position 4-20, high impressions | On-page optimization |
| Striking Distance | Position 11-30, high volume | Content expansion, backlinks |
| Low CTR | CTR < 2%, high impressions | Title/meta optimization |
| Cannibalization | Same query, multiple URLs | Consolidate content |

## Output

Results are saved to:

```text
~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon
```

## Prerequisites

Requires exported data. If no data exists, suggest:

```bash
/seo-export all example.com --days 90
```

## Documentation

For full documentation, read `seo/ranking-opportunities.md`.
