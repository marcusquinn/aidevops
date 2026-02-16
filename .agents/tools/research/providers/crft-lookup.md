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
tech-stack-helper.sh scan example.com

# Tech stack detection only
tech-stack-helper.sh techs example.com

# Lighthouse scores only
tech-stack-helper.sh lighthouse example.com

# Meta tag preview
tech-stack-helper.sh meta example.com

# JSON output
tech-stack-helper.sh scan example.com --json

# Compare two sites
tech-stack-helper.sh compare site1.com site2.com
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

### Basic Scan

```bash
# Scan a website (returns tech stack + Lighthouse + meta)
tech-stack-helper.sh scan example.com

# Output includes:
# - Detected technologies grouped by category
# - Lighthouse scores (desktop + mobile)
# - Meta tag summary
# - Report URL for full details
```

### Technology Detection

```bash
# List detected technologies
tech-stack-helper.sh techs example.com

# Filter by category
tech-stack-helper.sh techs example.com --category frameworks
tech-stack-helper.sh techs example.com --category analytics
tech-stack-helper.sh techs example.com --category cms
```

### Lighthouse Scores

```bash
# Get Lighthouse scores
tech-stack-helper.sh lighthouse example.com

# Desktop only
tech-stack-helper.sh lighthouse example.com --strategy desktop

# Mobile only
tech-stack-helper.sh lighthouse example.com --strategy mobile
```

### Comparison

```bash
# Compare tech stacks of two sites
tech-stack-helper.sh compare site1.com site2.com

# Output shows:
# - Technologies unique to each site
# - Technologies in common
# - Lighthouse score comparison
```

### JSON Output

```bash
# Machine-readable output
tech-stack-helper.sh scan example.com --json

# JSON schema:
# {
#   "url": "example.com",
#   "report_url": "https://crft.studio/lookup/gallery/example",
#   "technologies": [
#     {"name": "React", "category": "JavaScript frameworks", "description": "..."}
#   ],
#   "lighthouse": {
#     "desktop": {"performance": 98, "accessibility": 100, "best_practices": 100, "seo": 100},
#     "mobile": {"performance": 74, "accessibility": 100, "best_practices": 100, "seo": 100}
#   },
#   "meta": {
#     "title": "...",
#     "description": "...",
#     "og_image": "..."
#   }
# }
```

## Integration with Other Agents

### With SEO Analysis

```bash
# Get tech stack and Lighthouse scores for SEO audit
tech-stack-helper.sh scan client-site.com --json | jq '.lighthouse'

# Cross-reference with PageSpeed for detailed metrics
pagespeed-helper.sh run client-site.com
```

### With Competitor Research

```bash
# Analyze competitor tech stacks
for site in competitor1.com competitor2.com competitor3.com; do
  tech-stack-helper.sh techs "$site" --json
done

# Compare your site against a competitor
tech-stack-helper.sh compare mysite.com competitor.com
```

### With Domain Research

```bash
# Discover subdomains, then check their tech stacks
domain-research-helper.sh subdomains example.com | while read -r sub; do
  tech-stack-helper.sh techs "$sub" 2>/dev/null
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
