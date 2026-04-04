---
description: Open Tech Explorer provider for website technology stack discovery
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

# Open Tech Explorer - Tech Stack Discovery Provider

## Quick Reference

- **Purpose**: Discover website technology stacks via OpenExplorer.tech
- **Helper**: `~/.aidevops/agents/scripts/tech-stack-helper.sh openexplorer <url>`
- **Source**: [github.com/turazashvili/openexplorer.tech](https://github.com/turazashvili/openexplorer.tech)
- **Cost**: Free, open-source, community-driven
- **API Auth**: Supabase anon key embedded in web app JS bundle; use Playwright for UI fallback
- **Rate Limits**: None documented

```bash
tech-stack-helper.sh openexplorer search github.com            # Search by URL
tech-stack-helper.sh openexplorer tech React                   # Search by technology
tech-stack-helper.sh openexplorer category "Frontend Framework"
tech-stack-helper.sh openexplorer analyse https://example.com  # Playwright (real-time)
tech-stack-helper.sh providers                                 # List all providers
tech-stack-helper.sh compare https://example.com               # Compare providers
```

**Use**: free lookups, metadata/performance/security signals, cross-checking, no API key needed.
**Avoid**: broad coverage beyond ~7k indexed sites, version detection, historical tracking, enterprise scale.

## API Integration

**Endpoint**: `{SUPABASE_URL}/functions/v1/search` (Supabase Edge Function)

| Param | Type | Description |
|-------|------|-------------|
| `q` | string | Free-text search (URL or technology name) |
| `tech` | string | Exact technology name filter |
| `category` | string | Technology category filter |
| `sort` | string | `last_scraped`, `url`, `load_time` |
| `order` | string | `asc`, `desc` |
| `page` | int | Page number (default: 1) |
| `limit` | int | Results per page (default: 20) |
| `responsive` / `https` / `spa` / `service_worker` | bool | Metadata filters |

**Response**: `results[].technologies[{name, category}]`, `results[].metadata{is_responsive, is_https, likely_spa, has_service_worker, page_load_time}`, `pagination{page, limit, total, totalPages}`

**Fallback**: URL not indexed → open `https://openexplorer.tech`, submit URL, wait for React SPA to render, parse results table. Helper tries API first, then Playwright.

## Provider Comparison

| Feature | OpenExplorer | Wappalyzer | BuiltWith | WhatRuns |
|---------|-------------|------------|-----------|----------|
| Cost | Free | Freemium | Paid | Free (limited) |
| Technologies | ~72 | 1,500+ | 50,000+ | 1,000+ |
| Websites indexed | ~7,000 | Millions | 300M+ | Millions |
| Version detection | No | Yes | Yes | Yes |
| API access | Supabase | REST API | REST API | Chrome only |
| Open source | Yes | Partial | No | No |
| Server-side detection | No | Yes | Yes | No |
| Metadata (perf/security) | Yes | Limited | Limited | No |
| Real-time updates | Yes | No | No | No |

## Category Normalisation

| OpenExplorer | Common Schema |
|-------------|---------------|
| Frontend Framework | `frontend-framework` |
| Backend | `backend-framework` |
| Analytics | `analytics` |
| CMS | `cms` |
| CDN | `cdn` |
| Payment | `payment` |
| Performance | `performance` |
| Security | `security` |
| Other | `other` |

## Troubleshooting

| Issue | Solution |
|-------|---------|
| API returns 401 | Supabase anon key may have changed; use Playwright fallback |
| No results for URL | URL not in database; try Playwright analysis |
| Stale data | Check `lastScraped` timestamp; depends on community visits |
| Slow response | Supabase Edge Functions have cold start; retry after 2-3 seconds |
