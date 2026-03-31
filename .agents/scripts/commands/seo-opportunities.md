---
description: Export SEO data and analyze for ranking opportunities in one step
agent: SEO
mode: subagent
---

Run the complete SEO export + analysis workflow in one step.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Full SEO opportunity workflow
- **Combines**: `/seo-export all` + `/seo-analyze`
- **Default range**: 90 days
- **Output**: Export TOON files plus one analysis report

## Usage

```bash
# Full workflow with default 90 days
/seo-opportunities example.com

# Custom date range
/seo-opportunities example.com --days 30
```

## Process

1. Parse `$ARGUMENTS` for domain and options.
2. Export from all configured platforms:

```bash
~/.aidevops/agents/scripts/seo-export-helper.sh all $DOMAIN --days $DAYS
```

3. Run full analysis:

```bash
~/.aidevops/agents/scripts/seo-analysis-helper.sh $DOMAIN
```

4. Summarize findings:
   - Top 10 quick wins
   - Top 10 striking-distance opportunities
   - Low-CTR pages needing optimization
   - Content cannibalization issues

## Output

Created files:

```text
~/.aidevops/.agent-workspace/work/seo-data/{domain}/{platform}-{start}-{end}.toon
~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon
```

## Recommendations

Prioritize recommendations in this order:

1. **Quick Wins** — fastest ROI, minimal effort, on-page only
2. **Low CTR** — title/meta changes with fast traffic upside
3. **Cannibalization** — consolidate ranking signals before new work
4. **Striking Distance** — higher effort, higher upside

## Documentation

- Export details: `seo/data-export.md`
- Analysis details: `seo/ranking-opportunities.md`
