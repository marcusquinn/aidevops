---
description: Run comprehensive SEO audit (technical, on-page, content quality, E-E-A-T)
agent: Build+
mode: subagent
---

Run a comprehensive SEO audit for the specified URL or domain.

URL/Target: $ARGUMENTS

## Quick Reference

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

### 1. Load the audit framework

Read these files before analysing the site:

- `~/.aidevops/agents/seo/seo-audit-skill.md` — priority order, technical checklist, on-page checklist, content quality review
- `~/.aidevops/agents/seo/seo-audit-skill/ai-writing-detection.md`
- `~/.aidevops/agents/seo/seo-audit-skill/aeo-geo-patterns.md`

Apply the skill's priority order: crawlability → technical → on-page → content → authority.

### 2. Gather baseline data

Use lightweight fetches first:

```bash
# robots.txt and sitemap
curl -s "https://$DOMAIN/robots.txt"
curl -s "https://$DOMAIN/sitemap.xml" | head -50

# Meta tags on homepage
curl -s "https://$DOMAIN" | grep -E '<(title|meta)' | head -20
```

If `--gsc` is set, export Search Console data:

```bash
~/.aidevops/agents/scripts/seo-export-gsc.sh "$DOMAIN"
```

Use browser automation only for checks that need rendering or field data:

- Core Web Vitals via PageSpeed Insights
- Structured data via Rich Results Test
- Mobile-friendliness
- Internal linking analysis

### 3. Audit in priority order

For each category, record status, evidence, impact, and the next action. Keep the write-up focused on ranked issues, not a long checklist dump.

### 4. Generate the report

Use this structure:

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

### Reporting rules

- Lead with the top three issues by impact.
- Separate critical fixes, near-term work, quick wins, and longer-term recommendations.
- If `--compare` is used, call out relative gaps vs the competitor.
- If `--output` is set, save the final report to that file.

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
