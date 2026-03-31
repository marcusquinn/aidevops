---
description: Analyze exported SEO data for ranking opportunities
agent: SEO
mode: subagent
---

Analyze exported SEO data for ranking opportunities, cannibalization, and optimization targets.

Target: $ARGUMENTS

## Quick Reference

- Input: TOON exports from `/seo-export`
- Helper: `~/.aidevops/agents/scripts/seo-analysis-helper.sh $ARGUMENTS`
- Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon`
- Modes: full analysis, `quick-wins`, `striking-distance`, `low-ctr`, `cannibalization`, `summary`

## Usage

```bash
# Full analysis
/seo-analyze example.com

# Focused views
/seo-analyze example.com quick-wins
/seo-analyze example.com striking-distance
/seo-analyze example.com low-ctr
/seo-analyze example.com cannibalization

# Export summary only
/seo-analyze example.com summary
```

## Workflow

1. Parse `$ARGUMENTS` for domain and analysis type.
2. Run the helper.
3. Return the report with concrete recommendations.

## Analysis Types

| Type | Criteria | Primary action |
|------|----------|----------------|
| Quick Wins | Position 4-20, high impressions | On-page optimization |
| Striking Distance | Position 11-30, high volume | Content expansion, backlinks |
| Low CTR | CTR < 2%, high impressions | Title/meta optimization |
| Cannibalization | Same query, multiple URLs | Consolidate content |

## Prerequisite

If no export exists, run:

```bash
/seo-export all example.com --days 90
```

## Documentation

See `seo/ranking-opportunities.md` for the full reference.
