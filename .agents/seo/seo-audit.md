---
description: Run comprehensive SEO audit (technical, on-page, content quality, E-E-A-T)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run a comprehensive SEO audit for: $ARGUMENTS

Options:
- `--scope=full|technical|on-page|content` (default: full)
- `--pages=N` — max pages to analyze (default: 10)
- `--gsc` — include Search Console data
- `--compare=competitor.com` — compare against competitor
- `--output=report.md` — save report to file

## Workflow

### 1. Preparation & Baseline

Read before analysis:
- `seo/seo-audit-skill.md` (priority: crawlability → technical → on-page → content → authority)
- `seo/seo-audit-skill/ai-writing-detection.md`
- `seo/seo-audit-skill/aeo-geo-patterns.md`

```bash
# robots.txt, sitemap, and homepage meta
curl -s "https://$DOMAIN/robots.txt"
curl -s "https://$DOMAIN/sitemap.xml" | head -50
curl -s "https://$DOMAIN" | grep -E '<(title|meta)' | head -20
```

If `--gsc`: `~/.aidevops/agents/scripts/seo-export-gsc.sh "$DOMAIN"`. Browser automation only for rendering/field data (Core Web Vitals, Structured Data, Mobile, Internal links).

### 2. Audit & Reporting

Audit in priority order. Lead with top 3 issues by impact. Separate fixes by priority (Critical, High, Quick Wins, Long-Term). If `--compare`, call out gaps vs competitor. If `--output`, save to file.

```markdown
## SEO Audit Report: [DOMAIN]
**Date:** YYYY-MM-DD | **Scope:** [scope]

### Executive Summary
- **Overall Health:** Good / Needs Work / Critical Issues
- **Top 3 Priority Issues:** [with impact level]

### Technical SEO
| Issue | Impact | Evidence | Fix | Priority |
|-------|--------|----------|-----|----------|
| HTTPS | | | | |
| robots.txt | | | | |
| Sitemap | | | | |
| Core Web Vitals | | | | |
| Mobile | | | | |

### On-Page SEO
| Issue | Impact | Evidence | Fix | Priority |
|-------|--------|----------|-----|----------|
| Title | | | | |
| Meta Description | | | | |
| H1 | | | | |
| Image Alt Text | | | | |

### Content Quality
- E-E-A-T Score, Content Depth, AI Writing Patterns

### Prioritized Action Plan
- **Critical** (fix immediately) | **High** (this week) | **Quick Wins** | **Long-Term**
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

- `seo/seo-audit-skill.md` — Full audit framework
- `seo/google-search-console.md` — GSC integration
- `seo/dataforseo.md` — DataForSEO API
- `commands/performance.md` — Performance audit command
