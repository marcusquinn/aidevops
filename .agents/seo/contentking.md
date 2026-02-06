---
description: Conductor Website Monitoring (formerly ContentKing) real-time SEO monitoring via REST API (curl-based, no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# ContentKing / Conductor Monitoring - Real-time SEO Monitoring API

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-time SEO auditing, 24/7 monitoring, change tracking, issue detection, log file analysis
- **Brand**: ContentKing was acquired by Conductor in 2022; now branded as "Conductor Website Monitoring"
- **API Base**: `https://api.contentkingapp.com`
- **App**: `https://app.contentkingapp.com`
- **Auth**: Bearer token in `Authorization` header, stored in `~/.config/aidevops/credentials.sh` as `CONTENTKING_API_TOKEN`
- **Docs**: `https://support.conductor.com/en_US/conductor-monitoring-apis`
- **No MCP required** - uses curl directly

**APIs available**:

| API | Purpose | Version |
|-----|---------|---------|
| Reporting API | Extract data and metrics | v2.0 (recommended) |
| CMS API | Trigger priority page audits | v1 |
| Data Enrichment API | Enrich page data with custom metadata | v2.0 |

**Rate limits**: 6 requests/second/IP. Returns `429` for 1 minute when exceeded.

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/credentials.sh
```

All requests require these headers:

```bash
CK_HEADERS=(-H "Authorization: token $CONTENTKING_API_TOKEN" -H "Content-Type: application/json")
```

The `Authorization` header value must be the string `token` followed by a space and then the API token.

## Reporting API v2.0

### List Websites

```bash
curl -s "https://api.contentkingapp.com/v2/entities/websites" \
  "${CK_HEADERS[@]}" | jq .
```

Response:

```json
{
  "data": [
    {
      "id": "1-234",
      "app_url": "https://app.contentkingapp.com/websites/1-234/dashboard",
      "domain": "https://www.example.com",
      "name": "My Website",
      "page_capacity": 1000
    }
  ]
}
```

### List Segments

```bash
curl -s "https://api.contentkingapp.com/v2/entities/segments?website_id=1-234" \
  "${CK_HEADERS[@]}" | jq .
```

### Get Website Statistics

```bash
curl -s "https://api.contentkingapp.com/v2/data/statistics?website_id=1-234&scope=website" \
  "${CK_HEADERS[@]}" | jq .
```

Query parameters:

| Param | Description |
|-------|-------------|
| `website_id` | Required. From `/v2/entities/websites` |
| `scope` | Required. `website`, `segment:{id}`, or `segment_label:{label}` |

Response includes: health score, issue count, URL counts by type (page, redirect, missing, server_error, unreachable), and breakdowns for titles, meta descriptions, H1s, Open Graph, Twitter cards, indexability, hreflang, Lighthouse metrics, and more.

### List Pages

```bash
curl -s "https://api.contentkingapp.com/v2/data/pages?website_id=1-234&per_page=100&page=1" \
  "${CK_HEADERS[@]}" | jq .
```

Query parameters:

| Param | Description |
|-------|-------------|
| `website_id` | Required |
| `per_page` | Required. 1-1000 |
| `page` | Optional. Page number |
| `page_cursor` | Optional. For efficient large dataset pagination (takes precedence over `page`) |
| `sort` | Optional. Set to `url` |
| `direction` | Optional. `asc` or `desc` |

Each page record includes: URL, status code, title, meta description, H1, canonical, health score, indexability flags, Open Graph/Twitter metadata, internal/external link counts, Lighthouse metrics, Google Analytics data, GSC data, log file analysis data (Google, Bing, OpenAI, Perplexity bot frequencies), schema.org types, and custom elements.

### Get Single Page

```bash
curl -s "https://api.contentkingapp.com/v2/data/page?website_id=1-234&url=https://www.example.com/page" \
  "${CK_HEADERS[@]}" | jq .
```

### List Issues

```bash
curl -s "https://api.contentkingapp.com/v2/data/issues?website_id=1-234&per_page=100&page=1" \
  "${CK_HEADERS[@]}" | jq .
```

Query parameters:

| Param | Description |
|-------|-------------|
| `website_id` | Required |
| `per_page` | Required. 1-1000 |
| `page` | Optional |
| `page_cursor` | Optional |
| `scope` | Optional. `website`, `segment:{id}`, or `segment_label:{label}` |

### Get Issue Detail

```bash
curl -s "https://api.contentkingapp.com/v2/data/issue?website_id=1-234&issue_id=title_missing" \
  "${CK_HEADERS[@]}" | jq .
```

### List Alerts

```bash
curl -s "https://api.contentkingapp.com/v2/data/alerts?website_id=1-234&per_page=100" \
  "${CK_HEADERS[@]}" | jq .
```

## CMS API (Priority Auditing)

Trigger immediate re-audit of a page after publishing changes:

```bash
curl -s -X POST "https://api.contentkingapp.com/v1/check_url" \
  "${CK_HEADERS[@]}" \
  -d '{"url": "https://www.example.com/updated-page/"}' | jq .
```

Response: `{"status": "ok"}`

## Common Workflows

### Health Check Dashboard

```bash
source ~/.config/aidevops/credentials.sh
CK_API="https://api.contentkingapp.com"
CK_HEADERS=(-H "Authorization: token $CONTENTKING_API_TOKEN" -H "Content-Type: application/json")

# Get all websites
WEBSITES=$(curl -s "$CK_API/v2/entities/websites" "${CK_HEADERS[@]}")
echo "$WEBSITES" | jq -r '.data[] | "\(.id)\t\(.domain)\t\(.name)"'

# Get health for each website
echo "$WEBSITES" | jq -r '.data[].id' | while read -r wid; do
  STATS=$(curl -s "$CK_API/v2/data/statistics?website_id=$wid&scope=website" "${CK_HEADERS[@]}")
  HEALTH=$(echo "$STATS" | jq -r '.data.health // "N/A"')
  ISSUES=$(echo "$STATS" | jq -r '.data.number_of_issues // "N/A"')
  DOMAIN=$(echo "$WEBSITES" | jq -r --arg wid "$wid" '.data[] | select(.id == $wid) | .domain')
  echo "$DOMAIN: health=$HEALTH issues=$ISSUES"
done
```

### Find Pages with SEO Issues

```bash
source ~/.config/aidevops/credentials.sh
CK_API="https://api.contentkingapp.com"
CK_HEADERS=(-H "Authorization: token $CONTENTKING_API_TOKEN" -H "Content-Type: application/json")

WEBSITE_ID="1-234"

# Pages missing titles
curl -s "$CK_API/v2/data/pages?website_id=$WEBSITE_ID&per_page=1000" \
  "${CK_HEADERS[@]}" | jq '[.data.urls[] | select(.title == null or .title == "")] | length'

# Non-indexable pages
curl -s "$CK_API/v2/data/pages?website_id=$WEBSITE_ID&per_page=1000" \
  "${CK_HEADERS[@]}" | jq '[.data.urls[] | select(.is_indexable == false)] | .[0:10] | .[].url'
```

### Trigger Audit After CMS Publish

```bash
source ~/.config/aidevops/credentials.sh
CK_HEADERS=(-H "Authorization: token $CONTENTKING_API_TOKEN" -H "Content-Type: application/json")

# After publishing a page, trigger priority audit
URLS=("https://www.example.com/new-post/" "https://www.example.com/updated-page/")

for url in "${URLS[@]}"; do
  PAYLOAD=$(jq -n --arg url "$url" '{url: $url}')
  RESULT=$(curl -s -X POST "https://api.contentkingapp.com/v1/check_url" \
    "${CK_HEADERS[@]}" -d "$PAYLOAD")
  echo "$url: $RESULT"
  sleep 0.2
done
```

## Error Handling

| Code | Meaning | Action |
|------|---------|--------|
| `200` | Success | Process response |
| `400` | Invalid URL or unknown website | Check URL format includes protocol and domain |
| `401` | Missing or invalid token | Regenerate token in Account > Integration Tokens |
| `403` | Terms of use not accepted | Accept Reporting API ToU in Account Settings |
| `404` | Website or resource not found | Verify website ID |
| `422` | Malformed authorization | Use `token {key}` format in Authorization header |
| `429` | Rate limited | Wait 1 minute, then retry |

## Key Features

- **24/7 Real-time Monitoring**: Continuous crawling without manual triggers
- **Change Tracking**: Tracks all on-page changes with timestamps
- **Issue Detection**: Automatic SEO issue identification and prioritization
- **Health Score**: 0-1000 score per page and per website
- **Log File Analysis**: Bot crawl frequency data for Google, Bing, OpenAI, and Perplexity
- **Lighthouse Integration**: Core Web Vitals and performance metrics per page
- **Analytics Integration**: Google Analytics (UA + GA4), Adobe Analytics, GSC data per page
- **Segments**: Group pages for targeted monitoring and reporting
- **Custom Elements**: Extract custom HTML elements via CSS selectors
- **Alerts**: Configurable alerts for SEO changes (Slack, email, Microsoft Teams)
- **WordPress Plugin**: Direct integration for WordPress sites

## Setup

1. Sign up at `https://www.contentkingapp.com` (free trial available)
2. Get API token from Account > Integration Tokens
3. Store securely:

```bash
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set CONTENTKING_API_TOKEN "your_token"
```

4. Verify:

```bash
source ~/.config/aidevops/credentials.sh
curl -s "https://api.contentkingapp.com/v2/entities/websites" \
  -H "Authorization: token $CONTENTKING_API_TOKEN" \
  -H "Content-Type: application/json" | jq .
```

## Related Agents

- `seo/site-crawler.md` - On-demand SEO crawling (Screaming Frog-like)
- `seo/google-search-console.md` - Search performance data
- `seo/eeat-score.md` - E-E-A-T content quality scoring
- `tools/browser/pagespeed.md` - Performance auditing
