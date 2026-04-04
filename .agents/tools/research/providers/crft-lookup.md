---
description: CRFT Lookup tech stack detection, Lighthouse scores, meta tags, and sitemap visualization
mode: subagent
model: sonnet
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CRFT Lookup - Tech Stack Detection Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Service**: [crft.studio/lookup](https://crft.studio/lookup) — free, no API key
- **Helper**: `~/.aidevops/agents/scripts/tech-stack-helper.sh`
- **Provider flag**: `--provider crft` (default in tech-stack-helper.sh)
- **Report URL**: `https://crft.studio/lookup/gallery/{domain-slug}` (30-day retention)

**Capabilities**:

| Feature | Details |
|---------|---------|
| Tech detection | 2500+ fingerprints (frameworks, CMS, analytics, hosting, CDN) |
| Lighthouse | Performance, accessibility, SEO, best practices (desktop + mobile) |
| Meta tags | OG tags, Twitter cards, search engine previews |
| Sitemap | Interactive tree visualization, page hierarchy |

**Quick Commands**:

```bash
# Full analysis
tech-stack-helper.sh lookup example.com --provider crft

# JSON output
tech-stack-helper.sh lookup example.com --provider crft --json

# Markdown report
tech-stack-helper.sh report example.com --provider crft
```

<!-- AI-CONTEXT-END -->

## Usage

```bash
# JSON output with schema
tech-stack-helper.sh lookup example.com --provider crft --json
# {
#   "url": "https://example.com", "domain": "example.com",
#   "technologies": [{"name": "React", "category": "ui-libs", "version": "18.2", "confidence": 1.0}],
#   "categories": [{"category": "ui-libs", "count": 1, "technologies": ["React"]}]
# }

# SEO integration
tech-stack-helper.sh lookup client-site.com --provider crft --json | jq '.technologies'
pagespeed-helper.sh run client-site.com  # detailed Lighthouse

# Competitor batch
for site in competitor1.com competitor2.com competitor3.com; do
  tech-stack-helper.sh lookup "$site" --provider crft --json
done

# Subdomain sweep
domain-research-helper.sh subdomains example.com | while read -r sub; do
  tech-stack-helper.sh lookup "$sub" --provider crft 2>/dev/null
done
```

## Limitations

- Public sites only (no localhost, intranet, or password-protected pages)
- No API — helper uses web scraping; ~5s between scans recommended
- Reports expire after 30 days; new scans ~20s (headless Chromium + Lighthouse)

## Alternatives

| Feature | CRFT Lookup | Wappalyzer | BuiltWith | PageSpeed Insights |
|---------|-------------|------------|-----------|-------------------|
| Tech detection | 2500+ | 1000+ | 50000+ | No |
| Lighthouse scores | Yes | No | No | Yes (detailed) |
| Meta tag preview | Yes | No | No | No |
| Sitemap visualization | Yes | No | No | No |
| API | No (web only) | Yes (paid) | Yes (paid) | Yes (free) |
| Price | Free | Freemium | Paid | Free |
| CLI | Via helper | Browser ext | No | Via npm |
| Use with CRFT | Overview → PSI deep dive | Batch/CLI vs real-time | Current snapshot vs history | — |

## Related

- `tools/browser/pagespeed.md` — detailed Lighthouse analysis
- `seo/site-crawler.md` — website crawling
- `seo/domain-research.md` — DNS intelligence
- `tools/browser/browser-automation.md` — browser automation for scraping
