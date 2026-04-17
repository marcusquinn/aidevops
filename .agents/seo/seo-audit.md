---
description: Run comprehensive SEO audit (technical, on-page, content quality, E-E-A-T)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

### 1. Preparation & Baseline

Read audit framework files before analysis:
- `seo/seo-audit-skill.md` (priority: crawlability → technical → on-page → content → authority)
- `seo/seo-audit-skill/ai-writing-detection.md`
- `seo/seo-audit-skill/aeo-geo-patterns.md`

Gather baseline data using lightweight fetches:

```bash
# robots.txt, sitemap, and homepage meta
curl -s "https://$DOMAIN/robots.txt"
curl -s "https://$DOMAIN/sitemap.xml" | head -50
curl -s "https://$DOMAIN" | grep -E '<(title|meta)' | head -20
```

If `--gsc` set, export Search Console: `~/.aidevops/agents/scripts/seo-export-gsc.sh "$DOMAIN"`.
Use browser automation only for rendering/field data (Core Web Vitals, Structured Data, Mobile, Internal links).

### 2. Audit & Reporting

Audit in priority order. Record status, evidence, impact, and next action. Focus on ranked issues.

**Report Structure:**

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
- **Critical** (fix immediately) | **High Priority** (this week) | **Quick Wins** (easy) | **Long-Term**
```

**Rules:**
- Lead with top 3 issues by impact.
- Separate fixes by priority (Critical, High, Quick Wins, Long-Term).
- If `--compare` used, call out gaps vs competitor.
- If `--output` set, save to file.

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
- `seo/video-seo.md` — video optimisation checklist (YouTube + Key Moments + LLM surfaces)
