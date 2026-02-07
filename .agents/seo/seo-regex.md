---
description: Regex patterns for Google Search Console filtering and SEO analysis
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# SEO Regex Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Regex patterns for GSC query filtering, URL analysis, and SEO data processing
- **Context**: Google Search Console supports RE2 regex in Performance reports
- **Helpers**: `scripts/seo-analysis-helper.sh`, `scripts/keyword-research-helper.sh`

**GSC regex syntax**: RE2 (no lookaheads/lookbehinds, no backreferences). Use in Performance > Filter > Query/Page > Matches regex.

<!-- AI-CONTEXT-END -->

## GSC Query Filters

### Brand vs Non-Brand

```regex
# Brand queries (replace with your brand)
(brand|brandname|brand\.com)

# Non-brand (negate in GSC UI, or use custom regex)
^(?!.*(brand|brandname)).*$
# Note: GSC doesn't support lookaheads. Use "Does not match" filter instead.
```

### Question Queries

```regex
# All questions
^(what|how|why|when|where|who|which|can|does|is|are|do|should|will|would)\b

# How-to queries
^how (to|do|does|can|should)

# Comparison queries
(vs|versus|compared to|or|better than|difference between)
```

### Intent Classification

```regex
# Informational
^(what|how|why|guide|tutorial|learn|example|definition)

# Transactional
(buy|price|cost|cheap|deal|discount|coupon|order|purchase|shop)

# Navigational
(login|sign in|dashboard|account|support|contact)

# Commercial investigation
(best|top|review|comparison|alternative|vs)
```

### Long-Tail Queries

```regex
# 4+ word queries
^\S+\s+\S+\s+\S+\s+\S+

# 6+ word queries
^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+
```

## GSC Page Filters

```regex
# Blog posts
/blog/

# Product pages
/products?/

# Category pages
/category/|/collections?/

# Paginated pages
/page/[0-9]+

# Specific language
/en/|/en-us/

# Exclude certain paths
# Use "Does not match" with: /(admin|api|staging)/
```

## URL Analysis Patterns

```bash
# Extract slugs from URLs
echo "$urls" | sed 's|.*/||' | sort | uniq -c | sort -rn

# Find duplicate content patterns
rg -o '/[^/]+/[^/]+/$' urls.txt | sort | uniq -d

# Identify thin content URLs (short slugs)
rg '/[a-z]{1,3}/$' urls.txt

# Find non-canonical patterns
rg '(index\.html|index\.php|\?|#)' urls.txt
```

## Keyword Grouping

```bash
# Group by topic (pipe GSC export through these)
rg -i 'docker|container|kubernetes' keywords.csv
rg -i 'deploy|deployment|ci.?cd|pipeline' keywords.csv
rg -i 'monitor|alert|log|observ' keywords.csv

# Extract modifiers
rg -o '\b(best|top|free|open.?source|enterprise)\b' keywords.csv | sort | uniq -c | sort -rn
```

## Integration with aidevops

```bash
# Export GSC data and filter
seo-analysis-helper.sh striking-distance example.com | rg "^how"

# Keyword research with regex filtering
keyword-research-helper.sh research "devops tools" --filter "^(best|top)"
```

## Related

- `seo/google-search-console.md` - GSC API integration
- `seo/keyword-research.md` - Keyword research workflows
- `seo/ranking-opportunities.md` - Ranking opportunity analysis
- `scripts/seo-analysis-helper.sh` - SEO data analysis CLI
