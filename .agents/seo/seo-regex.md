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
- **GSC syntax**: RE2 — no lookaheads/lookbehinds/backreferences. Apply via Performance > Filter > Query/Page > Matches regex.
- **Helpers**: `scripts/seo-analysis-helper.sh`, `scripts/keyword-research-helper.sh`

<!-- AI-CONTEXT-END -->

## GSC Query Filters

```regex
# --- Brand vs Non-Brand ---
# Brand queries (replace with your brand)
(brand|brandname|brand\.com)
# Non-brand: GSC lacks lookaheads — use "Does not match" filter instead
^(?!.*(brand|brandname)).*$

# --- Question Queries ---
# All questions
^(what|how|why|when|where|who|which|can|does|is|are|do|should|will|would)\b
# How-to
^how (to|do|does|can|should)
# Comparisons
(vs|versus|compared to|or|better than|difference between)

# --- Intent Classification ---
# Informational
^(what|how|why|guide|tutorial|learn|example|definition)
# Transactional
(buy|price|cost|cheap|deal|discount|coupon|order|purchase|shop)
# Navigational
(login|sign in|dashboard|account|support|contact)
# Commercial investigation
(best|top|review|comparison|alternative|vs)

# --- Long-Tail ---
# 4+ words
^\S+\s+\S+\s+\S+\s+\S+
# 6+ words
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
# Exclude certain paths — use "Does not match" with:
/(admin|api|staging)/
```

## URL Analysis & Keyword Grouping

```bash
# --- URL Analysis ---
# Extract slugs from URLs
echo "$urls" | sed 's|.*/||' | sort | uniq -c | sort -rn
# Find duplicate content patterns
rg -o '/[^/]+/[^/]+/$' urls.txt | sort | uniq -d
# Identify thin content URLs (short slugs)
rg '/[a-z]{1,3}/$' urls.txt
# Find non-canonical patterns
rg '(index\.html|index\.php|\?|#)' urls.txt

# --- Keyword Grouping (pipe GSC export) ---
rg -i 'docker|container|kubernetes' keywords.csv
rg -i 'deploy|deployment|ci.?cd|pipeline' keywords.csv
rg -i 'monitor|alert|log|observ' keywords.csv
# Extract modifiers
rg -o '\b(best|top|free|open.?source|enterprise)\b' keywords.csv | sort | uniq -c | sort -rn

# --- Integration with aidevops ---
seo-analysis-helper.sh striking-distance example.com | rg "^how"
keyword-research-helper.sh research "devops tools" --filter "^(best|top)"
```

## Related

- `seo/google-search-console.md` - GSC API integration
- `seo/keyword-research.md` - Keyword research workflows
- `seo/ranking-opportunities.md` - Ranking opportunity analysis
- `scripts/seo-analysis-helper.sh` - SEO data analysis CLI
