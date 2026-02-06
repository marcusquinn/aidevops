---
description: Run comprehensive SEO audit (technical, on-page, content quality, E-E-A-T)
agent: Build+
mode: subagent
---

Run a comprehensive SEO audit for the specified URL or domain.

URL/Target: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

```text
Default: Full audit (technical + on-page + content)
Options:
  --scope=full|technical|on-page|content  Audit scope (default: full)
  --pages=N                               Max pages to analyze (default: 10)
  --gsc                                   Include Search Console data if available
  --compare=competitor.com                Compare against competitor
  --output=report.md                      Save report to file
```

### Step 2: Read SEO Audit Subagent

Read `~/.aidevops/agents/seo/seo-audit-skill.md` for:
- Complete audit framework and priority order
- Technical SEO checklist (crawlability, indexation, Core Web Vitals)
- On-page optimization checklist (titles, meta, headings, content)
- Content quality assessment (E-E-A-T signals)
- Common issues by site type

Also read reference files:
- `~/.aidevops/agents/seo/seo-audit-skill/references/ai-writing-detection.md`
- `~/.aidevops/agents/seo/seo-audit-skill/references/aeo-geo-patterns.md`

### Step 3: Gather Data

**Technical checks** (using browser automation or curl):

```bash
# Check robots.txt
curl -s "https://$DOMAIN/robots.txt"

# Check sitemap
curl -s "https://$DOMAIN/sitemap.xml" | head -50

# Check meta tags on homepage
curl -s "https://$DOMAIN" | grep -E '<(title|meta)' | head -20
```

**If --gsc flag provided**, use Google Search Console data:

```bash
# Export GSC data for the domain
~/.aidevops/agents/scripts/seo-export-gsc.sh "$DOMAIN"
```

**For deeper analysis**, use browser automation to:
- Check Core Web Vitals via PageSpeed Insights
- Validate structured data via Rich Results Test
- Check mobile-friendliness
- Analyze internal linking

### Step 4: Run Audit

Follow the priority order from seo-audit-skill.md:

1. **Crawlability & Indexation**
   - robots.txt analysis
   - Sitemap validation
   - Index status (site:domain.com)
   - Canonical tag check

2. **Technical Foundations**
   - HTTPS check
   - Core Web Vitals (via /performance or PageSpeed)
   - Mobile-friendliness
   - URL structure

3. **On-Page Optimization**
   - Title tags (unique, 50-60 chars, keyword placement)
   - Meta descriptions (unique, 150-160 chars, compelling)
   - Heading structure (single H1, logical hierarchy)
   - Image optimization (alt text, file sizes)

4. **Content Quality**
   - E-E-A-T signals (experience, expertise, authority, trust)
   - Content depth and uniqueness
   - AI writing patterns to avoid (from references)

5. **Authority & Links**
   - Internal linking structure
   - External link profile (if Ahrefs/DataForSEO available)

### Step 5: Generate Report

Output in actionable format:

```markdown
## SEO Audit Report: [DOMAIN]

**Audit Date:** YYYY-MM-DD
**Scope:** Full / Technical / On-Page / Content

### Executive Summary

- **Overall Health:** Good / Needs Work / Critical Issues
- **Top 3 Priority Issues:**
  1. [Issue] - [Impact: High/Medium/Low]
  2. [Issue] - [Impact: High/Medium/Low]
  3. [Issue] - [Impact: High/Medium/Low]

### Technical SEO

| Check | Status | Notes |
|-------|--------|-------|
| HTTPS | PASS/FAIL | |
| robots.txt | PASS/FAIL | |
| Sitemap | PASS/FAIL | |
| Core Web Vitals | PASS/FAIL | LCP: Xs, CLS: X.XX |
| Mobile-Friendly | PASS/FAIL | |

### On-Page SEO

| Element | Status | Recommendation |
|---------|--------|----------------|
| Title Tag | PASS/FAIL | |
| Meta Description | PASS/FAIL | |
| H1 Tag | PASS/FAIL | |
| Image Alt Text | PASS/FAIL | |

### Content Quality

- **E-E-A-T Score:** X/10
- **Content Depth:** Adequate / Thin / Comprehensive
- **AI Writing Patterns:** None detected / [Issues found]

### Prioritized Action Plan

**Critical (Fix Immediately):**
1. [Issue] - [Specific fix]

**High Priority (This Week):**
1. [Issue] - [Specific fix]

**Quick Wins (Easy, Immediate Benefit):**
1. [Issue] - [Specific fix]

**Long-Term Recommendations:**
1. [Recommendation]
```

## Examples

```bash
# Full audit of a domain
/seo-audit example.com

# Technical-only audit
/seo-audit example.com --scope=technical

# Include Search Console data
/seo-audit example.com --gsc

# Compare against competitor
/seo-audit example.com --compare=competitor.com

# Audit specific page
/seo-audit https://example.com/blog/article

# Save report to file
/seo-audit example.com --output=seo-report.md
```

## Related

- `seo/seo-audit-skill.md` - Full SEO audit subagent (imported skill)
- `seo/google-search-console.md` - GSC integration
- `seo/dataforseo.md` - DataForSEO API
- `seo/ahrefs.md` - Ahrefs API
- `tools/performance/pagespeed.md` - PageSpeed Insights
- `commands/performance.md` - Performance audit command
