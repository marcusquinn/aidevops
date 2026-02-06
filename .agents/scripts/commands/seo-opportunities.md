---
description: Export SEO data and analyze for ranking opportunities in one step
agent: SEO
mode: subagent
---

Export SEO data from all configured platforms and run full analysis in one step.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Complete SEO opportunity analysis workflow
- **Combines**: `/seo-export all` + `/seo-analyze`
- **Output**: Full analysis report with actionable opportunities

## Usage

```bash
# Full workflow with default 90 days
/seo-opportunities example.com

# Custom date range
/seo-opportunities example.com --days 30
```

## Process

1. Parse $ARGUMENTS to extract domain and options
2. Export from all configured platforms:

```bash
~/.aidevops/agents/scripts/seo-export-helper.sh all $DOMAIN --days $DAYS
```

3. Run full analysis:

```bash
~/.aidevops/agents/scripts/seo-analysis-helper.sh $DOMAIN
```

4. Present summary of findings:
   - Top 10 quick wins
   - Top 10 striking distance opportunities
   - Low CTR pages needing optimization
   - Content cannibalization issues

## Output

Two types of files are created:

**Export files** (one per platform):

```text
~/.aidevops/.agent-workspace/work/seo-data/{domain}/{platform}-{start}-{end}.toon
```

**Analysis file**:

```text
~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon
```

## Recommendations

After analysis, provide prioritized recommendations:

1. **Quick Wins** (do first)
   - Fastest ROI
   - Minimal effort required
   - On-page changes only

2. **Low CTR** (do second)
   - Title/meta changes are quick
   - Can significantly increase traffic

3. **Cannibalization** (do third)
   - Prevents wasted effort
   - Consolidates ranking signals

4. **Striking Distance** (longer term)
   - Requires more effort
   - Higher potential reward

## Documentation

- Export details: `seo/data-export.md`
- Analysis details: `seo/ranking-opportunities.md`
