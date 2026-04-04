---
description: Bing Webmaster Tools API integration via curl
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Quick Reference

- **API Base**: `https://ssl.bing.com/webmaster/api.svc/json/`
- **Auth**: query param `apikey=$BING_API_KEY`
- **Credentials**: `~/.config/aidevops/credentials.sh` → `BING_API_KEY`
- **Docs**: [Bing Webmaster API](https://www.bing.com/webmasters/help/webmaster-api-5f3c5e1e)

## Setup

1. [Bing Webmaster Tools](https://www.bing.com/webmasters/) → **Settings** → **API Access** → **Generate API Key**
2. Add to `~/.config/aidevops/credentials.sh`: `export BING_API_KEY="your_api_key_here"`
3. `source ~/.config/aidevops/credentials.sh`

## API Operations (`BASE="https://ssl.bing.com/webmaster/api.svc/json"`)

### Submit URL

```bash
curl -s -X POST "$BASE/SubmitUrl?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "url": "https://example.com/new-page"}'
```

### Batch Submit (up to 10,000/day)

```bash
curl -s -X POST "$BASE/SubmitUrlBatch?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "urlList": ["https://example.com/page1", "https://example.com/page2"]}'
```

### URL Inspection

```bash
curl -s -G "$BASE/GetUrlInfo" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com" \
  --data-urlencode "url=https://example.com/page"
```

### Search Analytics

```bash
curl -s -X POST "$BASE/GetQueryStats?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "startDate": "2025-01-01", "endDate": "2025-01-31"}'
```

### Sitemap Submit

```bash
curl -s -X POST "$BASE/SubmitFeed?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "feedUrl": "https://example.com/sitemap.xml"}'
```

### Sitemap List

```bash
curl -s -G "$BASE/GetFeedStats" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com"
```

## Troubleshooting

| Error | Cause / Fix |
|-------|-------------|
| HTTP 400 | Bad JSON or `siteUrl` mismatch (check http/https, www/non-www) |
| HTTP 401 | `BING_API_KEY` incorrect or revoked |
| HTTP 500 | Transient — retry |
| Quota exceeded | 10,000 URLs/day/site limit |

## Integration with SEO Audit

Used by `seo-audit-skill` for cross-engine verification: check GSC index status, check Bing index status, compare for engine-specific issues.
