---
description: Run comprehensive SEO audit (technical, on-page, content quality, E-E-A-T)
agent: Build+
mode: subagent
---

Run a comprehensive SEO audit for the specified URL or domain.

URL/Target: $ARGUMENTS

## Arguments

```text
Default: Full audit (technical + on-page + content)
Options:
  --scope=full|technical|on-page|content  Audit scope (default: full)
  --pages=N                               Max pages to analyze (default: 10)
  --gsc                                   Include Search Console data if available
  --compare=competitor.com                Compare against competitor
  --output=report.md                      Save report to file
```

## Workflow

### 1. Load Audit Framework

Read `~/.aidevops/agents/seo/seo-audit-skill.md` for the complete audit framework:
- Priority order (crawlability → technical → on-page → content → authority)
- Technical SEO checklist (Core Web Vitals thresholds, indexation checks)
- On-page optimization checklist
- Content quality assessment (E-E-A-T signals)

Also read reference files:
- `~/.aidevops/agents/seo/seo-audit-skill/ai-writing-detection.md`
- `~/.aidevops/agents/seo/seo-audit-skill/aeo-geo-patterns.md`

### 2. Gather Data

**Technical checks:**

```bash
# robots.txt and sitemap
curl -s "https://$DOMAIN/robots.txt"
curl -s "https://$DOMAIN/sitemap.xml" | head -50

# Meta tags on homepage
curl -s "https://$DOMAIN" | grep -E '<(title|meta)' | head -20
```

**With --gsc flag:**

```bash
~/.aidevops/agents/scripts/seo-export-gsc.sh "$DOMAIN"
```

**For deeper analysis** (browser automation):
- Core Web Vitals via PageSpeed Insights
- Structured data via Rich Results Test
- Mobile-friendliness
- Internal linking analysis

### 3. Run Audit

Follow the priority order from seo-audit-skill.md. For each category, check status and note issues.

### 4. Generate Report

Output format:

```markdown
## SEO Audit Report: [DOMAIN]
**Date:** YYYY-MM-DD | **Scope:** [scope]

### Executive Summary
- **Overall Health:** Good / Needs Work / Critical Issues
- **Top 3 Priority Issues:** [with impact level]

### Technical SEO
| Check | Status | Notes |
|-------|--------|-------|
| HTTPS / robots.txt / Sitemap / Core Web Vitals / Mobile |

### On-Page SEO
| Element | Status | Recommendation |
|---------|--------|----------------|
| Title / Meta Description / H1 / Image Alt Text |

### Content Quality
- E-E-A-T Score, Content Depth, AI Writing Patterns

### Prioritized Action Plan
- **Critical** (fix immediately)
- **High Priority** (this week)
- **Quick Wins** (easy, immediate benefit)
- **Long-Term** recommendations
```

## Examples

```bash
/seo-audit example.com                          # Full audit
/seo-audit example.com --scope=technical        # Technical only
/seo-audit example.com --gsc                    # Include Search Console
/seo-audit example.com --compare=competitor.com # Competitor comparison
/seo-audit https://example.com/blog/article     # Specific page
/seo-audit example.com --output=seo-report.md   # Save to file
```

## Related

- `seo/seo-audit-skill.md` — Full audit framework (imported skill)
- `seo/google-search-console.md` — GSC integration
- `seo/dataforseo.md` — DataForSEO API
- `commands/performance.md` — Performance audit command
