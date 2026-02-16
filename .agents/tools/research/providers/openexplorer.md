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

# Open Tech Explorer - Tech Stack Discovery Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover website technology stacks via OpenExplorer.tech
- **Helper**: `~/.aidevops/agents/scripts/tech-stack-helper.sh openexplorer <url>`
- **Source**: [github.com/turazashvili/openexplorer.tech](https://github.com/turazashvili/openexplorer.tech)
- **Cost**: Free, open-source, community-driven
- **API Auth**: Supabase anon key (embedded in web app, or use Playwright for web UI)
- **Rate Limits**: No documented rate limits (community project)

**Quick Commands**:

```bash
# Search by URL
tech-stack-helper.sh openexplorer search github.com

# Search by technology name
tech-stack-helper.sh openexplorer tech React

# Search by category
tech-stack-helper.sh openexplorer category "Frontend Framework"

# Analyse a URL via Playwright (full detection)
tech-stack-helper.sh openexplorer analyse https://example.com

# List all providers
tech-stack-helper.sh providers

# Compare providers for a URL
tech-stack-helper.sh compare https://example.com
```

<!-- AI-CONTEXT-END -->

## Overview

Open Tech Explorer is a free, open-source platform for discovering website technology
stacks. It combines community-driven data collection (via a Chrome extension) with a
Supabase-backed search API. The platform detects frameworks, libraries, analytics tools,
and architectural patterns.

## Architecture

- **Frontend**: React 18 SPA (Vite + Tailwind CSS), hosted on Netlify
- **Backend**: Supabase (PostgreSQL + Edge Functions in Deno)
- **Detection**: Chrome Extension (Manifest V3) with content scripts
- **Data Model**: `websites` -> `website_technologies` -> `technologies` (name, category)

## Detection Method

The Chrome extension performs client-side detection by inspecting:

| Signal | Examples |
|--------|----------|
| Global JS objects | `window.React`, `window.Vue`, `window.angular` |
| DOM patterns | Meta tags, script src attributes, link tags |
| Network requests | CDN patterns, API endpoints |
| Runtime features | Service Workers, HTTPS, SPA detection |
| Metadata | Responsive design, CSP headers, page load time |

**Detection depth**: ~72 technologies across categories including Frontend Frameworks,
Backend, Analytics, Payment, CMS, CDN, and Performance tools.

## API Integration

### Supabase Edge Function API

The search API is a Supabase Edge Function. It requires the Supabase project URL and
anon key (public, embedded in the web app's JS bundle).

**Endpoint**: `{SUPABASE_URL}/functions/v1/search`

**Parameters**:

| Param | Type | Description |
|-------|------|-------------|
| `q` | string | Free-text search (URL or technology name) |
| `tech` | string | Exact technology name filter |
| `category` | string | Technology category filter |
| `sort` | string | Sort field: `last_scraped`, `url`, `load_time` |
| `order` | string | Sort direction: `asc`, `desc` |
| `page` | int | Page number (default: 1) |
| `limit` | int | Results per page (default: 20) |
| `responsive` | bool | Filter: responsive design |
| `https` | bool | Filter: HTTPS enabled |
| `spa` | bool | Filter: Single Page Application |
| `service_worker` | bool | Filter: has Service Worker |

**Response Schema**:

```json
{
  "results": [
    {
      "id": "uuid",
      "url": "example.com",
      "technologies": [
        { "name": "React", "category": "Frontend Framework" }
      ],
      "lastScraped": "2024-01-15T10:30:00Z",
      "metadata": {
        "is_responsive": true,
        "is_https": true,
        "likely_spa": true,
        "has_service_worker": false,
        "page_load_time": 1.2
      }
    }
  ],
  "suggestions": [],
  "pagination": {
    "page": 1,
    "limit": 20,
    "total": 150,
    "totalPages": 8
  }
}
```

### Playwright Fallback

When the API is unavailable or for real-time analysis of URLs not yet in the database,
use Playwright to interact with the web UI:

1. Navigate to `https://openexplorer.tech`
2. Enter URL in the search input
3. Wait for results to load (React SPA renders asynchronously)
4. Parse the results table for technology names and categories

The helper script implements both approaches with automatic fallback.

## Common Schema Mapping

OpenExplorer results are normalised to the common tech-stack schema used across all
providers in `tech-stack-helper.sh`:

```json
{
  "url": "example.com",
  "provider": "openexplorer",
  "timestamp": "2024-01-15T10:30:00Z",
  "technologies": [
    {
      "name": "React",
      "category": "frontend-framework",
      "version": null,
      "confidence": "community"
    }
  ],
  "metadata": {
    "https": true,
    "responsive": true,
    "spa": true,
    "service_worker": false,
    "page_load_time": 1.2
  }
}
```

**Category normalisation** (OpenExplorer -> common schema):

| OpenExplorer Category | Common Schema |
|----------------------|---------------|
| Frontend Framework | `frontend-framework` |
| Backend | `backend-framework` |
| Analytics | `analytics` |
| CMS | `cms` |
| CDN | `cdn` |
| Payment | `payment` |
| Performance | `performance` |
| Security | `security` |
| Other | `other` |

## Provider Comparison

### Strengths

- **Free and open-source**: No API key required, no cost
- **Community-driven**: Crowd-sourced data improves accuracy over time
- **Metadata-rich**: Includes performance, security, and architecture signals
- **Real-time search**: Supabase real-time subscriptions for live updates
- **Chrome extension**: Users contribute data passively while browsing
- **Filterable**: Metadata filters (HTTPS, SPA, responsive, service worker)

### Gaps

- **Small dataset**: ~7,000 websites vs millions in commercial tools
- **Limited detection depth**: ~72 technologies vs 1,500+ in Wappalyzer/BuiltWith
- **No version detection**: Does not report specific framework versions
- **No server-side detection**: Relies on client-side signals only (no HTTP header analysis)
- **Community dependency**: Data quality depends on extension adoption
- **No historical data**: No technology change tracking over time
- **Supabase dependency**: API requires Supabase project credentials

### vs Other Providers

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

### Recommended Use Cases

1. **Quick free lookups**: When you need basic tech stack info without API keys
2. **Community research**: Understanding technology adoption trends
3. **Metadata analysis**: When performance/security signals matter
4. **Complementary source**: Cross-reference with Wappalyzer/BuiltWith for validation
5. **Open-source projects**: When commercial tools are not an option

### Not Recommended For

1. **Comprehensive audits**: Dataset too small for reliable coverage
2. **Version-specific analysis**: No version detection capability
3. **Historical tracking**: No change-over-time data
4. **Enterprise-scale research**: Commercial tools have better coverage

## Troubleshooting

| Issue | Solution |
|-------|---------|
| API returns 401 | Supabase anon key may have changed; use Playwright fallback |
| No results for URL | URL may not be in the database; try Playwright analysis |
| Stale data | Check `lastScraped` timestamp; data depends on community visits |
| Slow response | Supabase Edge Functions have cold start; retry after 2-3 seconds |

## References

- Website: [openexplorer.tech](https://openexplorer.tech)
- GitHub: [turazashvili/openexplorer.tech](https://github.com/turazashvili/openexplorer.tech)
- Chrome Extension: [openexplorer.tech/extension](https://openexplorer.tech/extension)
