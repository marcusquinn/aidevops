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

# CRFT Lookup - Tech Stack Detection Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Detect website tech stacks, Lighthouse scores, meta tags, and sitemap structure
- **Service**: [crft.studio/lookup](https://crft.studio/lookup) (free, no API key required)
- **Helper**: `~/.aidevops/agents/scripts/tech-stack-helper.sh`
- **Provider**: `crft` (default provider in tech-stack-helper.sh)

**Capabilities**:

| Feature | Details |
|---------|---------|
| Tech detection | 2500+ fingerprints (frameworks, CMS, analytics, hosting, CDN) |
| Lighthouse | Performance, accessibility, SEO, best practices (desktop + mobile) |
| Meta tags | OG tags, Twitter cards, search engine previews |
| Sitemap | Interactive tree visualization, page hierarchy |
| Reports | Shareable URLs, 30-day retention |

**Quick Commands**:

```bash
# Full analysis (tech stack + Lighthouse + meta tags)
tech-stack-helper.sh lookup example.com --provider crft

# JSON output
tech-stack-helper.sh lookup example.com --provider crft --json

# Markdown report
tech-stack-helper.sh report example.com --provider crft
```

**Complementary Tools**:

| Tool | Strength | Use Together |
|------|----------|-------------|
| PageSpeed Insights | Detailed performance metrics | CRFT for overview, PSI for deep dive |
| Wappalyzer | Browser extension, real-time | CRFT for batch/CLI analysis |
| BuiltWith | Historical data, market share | CRFT for current snapshot |
| Unbuilt | Broader but shallower detection | CRFT for deeper fingerprinting |

<!-- AI-CONTEXT-END -->

## Overview

CRFT Lookup is a free website analysis tool from [CRFT Studio](https://crft.studio) that consolidates technology detection, performance scoring, meta tag previews, and sitemap visualization into a single report. It uses headless Chromium with a Wappalyzer-fork fingerprint database of 2500+ technologies.

### How It Works

1. Submit a URL to `crft.studio/lookup`
2. CRFT spins up a headless Chromium instance
3. Visits the website and analyzes HTML, JavaScript variables, response headers
4. Compares against 2500+ technology fingerprints
5. Runs Google Lighthouse for performance metrics
6. Extracts meta tags and sitemap structure
7. Generates a shareable report (retained 30 days)

### Report URL Structure

Reports are accessible at: `https://crft.studio/lookup/gallery/{domain-slug}`

Example: `https://crft.studio/lookup/gallery/basecamp` for `basecamp.com`

The gallery page shows pre-generated reports. For fresh scans, the tool submits the URL through the web interface and waits for the report to generate (~20 seconds).

## Detection Categories

### Technology Stack

- **JavaScript frameworks**: React, Vue, Svelte, Angular, Next.js, Nuxt, Astro, Stimulus, etc.
- **CMS platforms**: WordPress, Contentful, Sanity, Strapi, Ghost, etc.
- **Analytics**: Google Analytics, Plausible, PostHog, Hotjar, Mixpanel, etc.
- **Advertising**: Google Ads, Facebook Pixel, LinkedIn Insight Tag, etc.
- **Marketing automation**: Mailchimp, HubSpot, Intercom, Drift, etc.
- **CDN/Hosting**: Cloudflare, Vercel, Netlify, AWS, Akamai, Fastly, etc.
- **E-commerce**: Shopify, WooCommerce, Stripe, etc.
- **Email**: Mailchimp, SendGrid, Postmark, etc.
- **Miscellaneous**: Open Graph, Schema.org, PWA, etc.

### Lighthouse Scores

Lighthouse scores are included in CRFT reports but are not available as a standalone command via `tech-stack-helper.sh`. For dedicated Lighthouse analysis, use `pagespeed-helper.sh` or the PageSpeed Insights MCP tool.

Four categories scored 0-100 for both desktop and mobile:

| Category | What It Measures |
|----------|-----------------|
| Performance | Loading speed, interactivity, visual stability |
| Accessibility | WCAG compliance, screen reader support |
| Best Practices | Security, modern APIs, console errors |
| SEO | Meta tags, crawlability, mobile-friendliness |

### Meta Tags

- **Title**: Page title with character count
- **Description**: Meta description with character count
- **Open Graph**: Image, title, description for social sharing
- **Twitter Cards**: Twitter-specific meta tags
- **Favicon**: Site icon detection

## Usage

### Basic Lookup

```bash
# Lookup a website (returns tech stack via all available providers)
tech-stack-helper.sh lookup example.com

# Use CRFT provider specifically
tech-stack-helper.sh lookup example.com --provider crft

# Output includes:
# - Detected technologies grouped by category
# - Confidence scores based on provider agreement
# - Report URL for full details (CRFT provider)
```

### Markdown Report

```bash
# Generate a full markdown report
tech-stack-helper.sh report example.com --provider crft
```

### JSON Output

```bash
# Machine-readable output
tech-stack-helper.sh lookup example.com --provider crft --json

# JSON schema (merged multi-provider output):
# {
#   "url": "https://example.com",
#   "domain": "example.com",
#   "scan_time": "2025-01-15T12:00:00Z",
#   "provider_count": 1,
#   "providers": ["crft"],
#   "technology_count": 5,
#   "technologies": [
#     {"name": "React", "category": "ui-libs", "version": "18.2", "confidence": 1.0}
#   ],
#   "categories": [
#     {"category": "ui-libs", "count": 1, "technologies": ["React"]}
#   ]
# }
```

## Integration with Other Agents

### With SEO Analysis

```bash
# Get tech stack for SEO audit
tech-stack-helper.sh lookup client-site.com --provider crft --json | jq '.technologies'

# Cross-reference with PageSpeed for detailed Lighthouse metrics
pagespeed-helper.sh run client-site.com
```

### With Competitor Research

```bash
# Analyze competitor tech stacks
for site in competitor1.com competitor2.com competitor3.com; do
  tech-stack-helper.sh lookup "$site" --provider crft --json
done
```

### With Domain Research

```bash
# Discover subdomains, then check their tech stacks
domain-research-helper.sh subdomains example.com | while read -r sub; do
  tech-stack-helper.sh lookup "$sub" --provider crft 2>/dev/null
done
```

## Limitations

- **Public sites only**: Cannot scan localhost, intranet, or password-protected pages
- **No API**: Web-only interface; helper script uses web scraping
- **Report retention**: Reports expire after 30 days
- **Rate limiting**: No documented rate limits, but be respectful (~5s between scans)
- **Scan time**: ~20 seconds per scan (headless Chromium + Lighthouse)
- **Gallery only**: Pre-scanned sites available instantly; new scans require submission

## Alternatives Comparison

| Feature | CRFT Lookup | Wappalyzer | BuiltWith | PageSpeed Insights |
|---------|-------------|------------|-----------|-------------------|
| Tech detection | 2500+ | 1000+ | 50000+ | No |
| Lighthouse scores | Yes | No | No | Yes (detailed) |
| Meta tag preview | Yes | No | No | No |
| Sitemap visualization | Yes | No | No | No |
| API | No (web only) | Yes (paid) | Yes (paid) | Yes (free) |
| Price | Free | Freemium | Paid | Free |
| CLI | Via helper | Browser ext | No | Via npm |

## Related Agents

- `tools/browser/pagespeed.md` - Detailed Lighthouse analysis
- `seo/site-crawler.md` - Website crawling
- `seo/domain-research.md` - DNS intelligence
- `tools/browser/browser-automation.md` - Browser automation for scraping
