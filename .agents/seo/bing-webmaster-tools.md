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
- **Auth**: API Key (passed as query parameter `apikey`)
- **Credentials**: Store API Key in `~/.config/aidevops/credentials.sh` as `BING_API_KEY`
- **Capabilities**: Submit URLs, URL inspection, Search analytics, Sitemap management
- **Docs**: [Bing Webmaster API](https://www.bing.com/webmasters/help/webmaster-api-5f3c5e1e)

## Setup Steps

### 1. Generate API Key

1. Log in to [Bing Webmaster Tools](https://www.bing.com/webmasters/)
2. Go to **Settings** (gear icon) → **API Access**
3. Click **API Key** → **Generate API Key**
4. Copy the key

### 2. Configure Environment

Add the key to your secure environment file:

```bash
# Add to ~/.config/aidevops/credentials.sh
export BING_API_KEY="your_api_key_here"
```

Reload the environment:

```bash
source ~/.config/aidevops/credentials.sh
```

## API Operations

### Submit URL for Indexing

Submit a URL to Bing for immediate crawling.

```bash
# Submit a single URL
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrl?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "siteUrl": "https://example.com",
    "url": "https://example.com/new-page"
  }'
```

### Batch Submit URLs

Submit multiple URLs (up to 10,000 per day).

```bash
# Submit multiple URLs
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrlBatch?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "siteUrl": "https://example.com",
    "urlList": [
      "https://example.com/page1",
      "https://example.com/page2",
      "https://example.com/page3"
    ]
  }'
```

### Get URL Inspection Data

Check the index status and crawl details of a URL.

```bash
# Inspect URL
curl -s -G "https://ssl.bing.com/webmaster/api.svc/json/GetUrlInfo" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com" \
  --data-urlencode "url=https://example.com/page"
```

### Get Search Analytics (Query Stats)

Retrieve traffic data (clicks, impressions, position) by query.

```bash
# Get Query Stats
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/GetQueryStats?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "siteUrl": "https://example.com",
    "startDate": "2025-01-01",
    "endDate": "2025-01-31"
  }'
```

### Sitemap Management

#### Submit Sitemap

```bash
curl -s -X POST "https://ssl.bing.com/webmaster/api.svc/json/SubmitFeed?apikey=$BING_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "siteUrl": "https://example.com",
    "feedUrl": "https://example.com/sitemap.xml"
  }'
```

#### Get Sitemaps (Feeds)

```bash
curl -s -G "https://ssl.bing.com/webmaster/api.svc/json/GetFeedStats" \
  --data-urlencode "apikey=$BING_API_KEY" \
  --data-urlencode "siteUrl=https://example.com"
```

## Troubleshooting

### HTTP 400 Bad Request

- Check JSON syntax in request body
- Verify `siteUrl` matches exactly what is registered in Bing Webmaster Tools (including http/https and www/non-www)

### HTTP 401 Unauthorized

- Verify `BING_API_KEY` is correct
- Ensure the API key has not been revoked

### HTTP 500 Internal Server Error

- Retry the request
- Check Bing Webmaster Tools status

### Quota Limits

- **SubmitUrl**: 10,000 URLs per day per site
- **Crawl Rate**: Dependent on site authority and history

<!-- AI-CONTEXT-END -->

## Integration with SEO Audit

This subagent is designed to be used by the `seo-audit-skill` to perform cross-engine verification.

**Workflow:**
1. Check GSC for index status
2. Check Bing for index status
3. Compare results to identify engine-specific issues
