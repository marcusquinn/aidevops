---
description: PageSpeed Insights and Lighthouse performance testing
mode: subagent
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

# PageSpeed Insights & Lighthouse Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/pagespeed-helper.sh`
- **Commands**: `audit [url]` | `lighthouse [url] [format]` | `accessibility [url]` | `wordpress [url]` | `bulk [file]` | `report [json]`
- **Install**: `brew install lighthouse jq bc` or `.agents/scripts/pagespeed-helper.sh install-deps`
- **API Key**: Optional — https://console.cloud.google.com/ → Enable PageSpeed Insights API → `export GOOGLE_API_KEY="..."`
- **Rate Limits**: 25 req/100s (no key), 25,000/day (with key)
- **Reports**: `~/.ai-devops/reports/pagespeed/`
- **Core Web Vitals**: FCP (<1.8s good, >3s poor) | LCP (<2.5s good, >4s poor) | CLS (<0.1 good, >0.25 poor) | FID (<100ms good, >300ms poor)
- **Additional metrics**: TTFB (server response), Speed Index (visual display speed), Total Blocking Time (main thread blocked)
- **Accessibility**: Lighthouse score + WCAG-mapped failed audits — use `accessibility [url]`
- **Deep a11y testing**: `tools/accessibility/accessibility.md` (pa11y, contrast, email checks)
- **WordPress**: Plugin audits, image optimization, caching recommendations

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Install dependencies (jq, lighthouse npm -g, bc)
./.agents/scripts/pagespeed-helper.sh install-deps

# Optional: MCP server
npm install -g mcp-pagespeed-server
```

## Usage

```bash
# Single site audit (desktop + mobile)
./.agents/scripts/pagespeed-helper.sh audit https://example.com

# Lighthouse comprehensive audit
./.agents/scripts/pagespeed-helper.sh lighthouse https://example.com html

# Accessibility audit (score + WCAG-mapped failures)
./.agents/scripts/pagespeed-helper.sh accessibility https://example.com

# WordPress-specific analysis
./.agents/scripts/pagespeed-helper.sh wordpress https://myblog.com

# Bulk audit from file (one URL per line)
./.agents/scripts/pagespeed-helper.sh bulk websites.txt

# Generate recommendations from saved JSON report
./.agents/scripts/pagespeed-helper.sh report ~/.ai-devops/reports/pagespeed/lighthouse_20241110_143022.json

# Custom Lighthouse categories
lighthouse https://example.com \
  --only-categories=performance,accessibility \
  --output=json --output-path=custom-report.json

# Cron: weekly bulk audit
0 9 * * 1 /path/to/pagespeed-helper.sh bulk /path/to/websites.txt
```

## Accessibility Output

Every `lighthouse` and `accessibility` command extracts accessibility score, failed audits, and WCAG-mapped issues alongside performance data.

**Failed audit categories:** Contrast (WCAG 1.4.3/1.4.6) | ARIA attributes (WCAG 4.1.2) | Labels/names (WCAG 1.1.1, 1.3.1, 2.4.6) | Keyboard/focus (WCAG 2.1.1, 2.4.7) | Structure/semantics (WCAG 1.3.1, 2.4.1)

**Score thresholds:** 90–100 = Good | 50–89 = Needs improvement (fix before next release) | 0–49 = Critical (fix immediately)

**Tool selection:**

| Need | Tool |
|------|------|
| Quick score + top failures | `pagespeed-helper.sh accessibility [url]` |
| WCAG-specific violation report | `accessibility-helper.sh pa11y [url]` |
| Contrast ratio checking | `accessibility-helper.sh contrast [fg] [bg]` |
| Email HTML accessibility | `accessibility-helper.sh email [file]` |
| Full audit (Lighthouse + pa11y) | `accessibility-helper.sh audit [url]` |

See `tools/accessibility/accessibility.md` for the full accessibility subagent.

## WordPress Optimizations

| Area | Action |
|------|--------|
| Plugins | Audit with Query Monitor; disable unused; prefer lightweight alternatives |
| Images | Convert to WebP; enable lazy loading; set explicit dimensions |
| Caching | Page: WP Rocket / W3 Total Cache; Object: Redis / Memcached; CDN: Cloudflare |
| Database | Remove post revisions, spam comments; optimize tables |
| Theme/code | Use lightweight themes; minify CSS/JS; remove unused code |

## Report Storage

`~/.ai-devops/reports/pagespeed/` — `pagespeed_YYYYMMDD_HHMMSS_desktop.json` | `lighthouse_YYYYMMDD_HHMMSS.html` | `lighthouse_YYYYMMDD_HHMMSS.json`

## MCP Integration

```json
{
  "pagespeed_audit": "Audit website performance",
  "lighthouse_analysis": "Comprehensive website analysis",
  "accessibility_audit": "Lighthouse accessibility score and failed audits",
  "performance_metrics": "Get Core Web Vitals",
  "optimization_recommendations": "Get actionable improvements"
}
```

## References

- `tools/accessibility/accessibility.md` — Dedicated accessibility subagent (pa11y, contrast, email)
- `tools/accessibility/accessibility-audit.md` — Lighthouse accessibility in performance audits
- https://pagespeed.web.dev/ | https://developers.google.com/web/tools/lighthouse | https://web.dev/vitals/ | https://www.w3.org/TR/WCAG21/
