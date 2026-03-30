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

# Bing Webmaster Tools Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary access**: Direct API via `curl`
- **API Endpoint**: `https://ssl.bing.com/webmaster/api.svc/json/`
- **Auth**: API Key as query param `apikey`
- **Credentials**: `~/.config/aidevops/credentials.sh` → `BING_API_KEY`
- **Capabilities**: Submit URLs, URL inspection, search analytics, sitemap management
- **Docs**: [Bing Webmaster API](https://www.bing.com/webmasters/help/webmaster-api-5f3c5e1e)

## Setup

1. Log in to [Bing Webmaster Tools](https://www.bing.com/webmasters/) → **Settings** → **API Access** → **Generate API Key**
2. Add to `~/.config/aidevops/credentials.sh`:

```bash
export BING_API_KEY="your_api_key_here"
```

3. `source ~/.config/aidevops/credentials.sh`

## API Operations

### Submit URL

```bash
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrl?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "url": "https://example.com/new-page"}'
```

### Batch Submit URLs (up to 10,000/day)

```bash
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrlBatch?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "siteUrl": "https://example.com",
    "urlList": ["https://example.com/page1", "https://example.com/page2"]
  }'
```

### URL Inspection

```bash
curl -s -G "https://ssl.bing.com/webmaster/api.svc/json/GetUrlInfo" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com" \
  --data-urlencode "url=https://example.com/page"
```

### Search Analytics (Query Stats)

```bash
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/GetQueryStats?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "startDate": "2025-01-01", "endDate": "2025-01-31"}'
```

### Sitemap — Submit

```bash
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitFeed?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "feedUrl": "https://example.com/sitemap.xml"}'
```

### Sitemap — List

```bash
curl -s -G "https://ssl.bing.com/webmaster/api.svc/json/GetFeedStats" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com"
```

## Troubleshooting

| Error | Cause / Fix |
|-------|-------------|
| HTTP 400 | Bad JSON syntax, or `siteUrl` doesn't match registered site (check http/https, www/non-www) |
| HTTP 401 | `BING_API_KEY` incorrect or revoked |
| HTTP 500 | Transient — retry; check Bing Webmaster Tools status |
| Quota exceeded | `SubmitUrl` limit: 10,000 URLs/day/site. Crawl rate depends on site authority. |

<!-- AI-CONTEXT-END -->

## Integration with SEO Audit

Used by `seo-audit-skill` for cross-engine verification:

1. Check GSC for index status
2. Check Bing for index status
3. Compare to identify engine-specific issues
