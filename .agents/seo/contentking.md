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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ContentKing / Conductor Monitoring - Real-time SEO Monitoring API

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-time SEO auditing, 24/7 monitoring, change tracking, issue detection, log file analysis
- **Brand**: ContentKing acquired by Conductor (2022); now "Conductor Website Monitoring"
- **API Base**: `https://api.contentkingapp.com`
- **App**: `https://app.contentkingapp.com`
- **Auth**: Bearer token (`Authorization: token $CONTENTKING_API_TOKEN`), stored in `~/.config/aidevops/credentials.sh`
- **Docs**: `https://support.conductor.com/en_US/conductor-monitoring-apis`
- **No MCP required** — uses curl directly
- **Rate limits**: 6 req/s/IP. `429` → wait 1 minute.

| API | Purpose | Version |
|-----|---------|---------|
| Reporting | Extract data and metrics | v2.0 (recommended) |
| CMS | Trigger priority page audits | v1 |
| Data Enrichment | Enrich page data with custom metadata | v2.0 |

<!-- AI-CONTEXT-END -->

## Authentication

All requests require auth headers. Set up once per script:

```bash
source ~/.config/aidevops/credentials.sh
CK_API="https://api.contentkingapp.com"
CK_HEADERS=(-H "Authorization: token $CONTENTKING_API_TOKEN" -H "Content-Type: application/json")
```

Format: `token` + space + API token value.

## Reporting API v2.0

### List Websites

```bash
curl -s "$CK_API/v2/entities/websites" "${CK_HEADERS[@]}" | jq .
```

Returns `data[]` with: `id`, `app_url`, `domain`, `name`, `page_capacity`.

### List Segments

```bash
curl -s "$CK_API/v2/entities/segments?website_id=1-234" "${CK_HEADERS[@]}" | jq .
```

### Get Website Statistics

```bash
curl -s "$CK_API/v2/data/statistics?website_id=1-234&scope=website" "${CK_HEADERS[@]}" | jq .
```

| Param | Description |
|-------|-------------|
| `website_id` | Required. From `/v2/entities/websites` |
| `scope` | Required. `website`, `segment:{id}`, or `segment_label:{label}` |

Returns: health score, issue count, URL counts by type (page, redirect, missing, server_error, unreachable), breakdowns for titles, meta descriptions, H1s, Open Graph, Twitter cards, indexability, hreflang, Lighthouse metrics.

### List Pages

```bash
curl -s "$CK_API/v2/data/pages?website_id=1-234&per_page=100&page=1" "${CK_HEADERS[@]}" | jq .
```

| Param | Description |
|-------|-------------|
| `website_id` | Required |
| `per_page` | Required. 1-1000 |
| `page` | Page number |
| `page_cursor` | For large datasets (takes precedence over `page`) |
| `sort` | Set to `url` |
| `direction` | `asc` or `desc` |

Each page record includes: URL, status code, title, meta description, H1, canonical, health score, indexability flags, Open Graph/Twitter metadata, internal/external link counts, Lighthouse metrics, Google Analytics data, GSC data, log file analysis (Google, Bing, OpenAI, Perplexity bot frequencies), schema.org types, custom elements.

### Get Single Page

```bash
curl -s "$CK_API/v2/data/page?website_id=1-234&url=https://www.example.com/page" "${CK_HEADERS[@]}" | jq .
```

### List Issues

```bash
curl -s "$CK_API/v2/data/issues?website_id=1-234&per_page=100&page=1" "${CK_HEADERS[@]}" | jq .
```

| Param | Description |
|-------|-------------|
| `website_id` | Required |
| `per_page` | Required. 1-1000 |
| `page` / `page_cursor` | Pagination |
| `scope` | `website`, `segment:{id}`, or `segment_label:{label}` |

### Get Issue Detail

```bash
curl -s "$CK_API/v2/data/issue?website_id=1-234&issue_id=title_missing" "${CK_HEADERS[@]}" | jq .
```

### List Alerts

```bash
curl -s "$CK_API/v2/data/alerts?website_id=1-234&per_page=100" "${CK_HEADERS[@]}" | jq .
```

## CMS API (Priority Auditing)

Trigger immediate re-audit after publishing:

```bash
curl -s -X POST "$CK_API/v1/check_url" "${CK_HEADERS[@]}" \
  -d '{"url": "https://www.example.com/updated-page/"}' | jq .
```

Returns `{"status": "ok"}`.

## Common Workflows

All workflows assume auth setup from [Authentication](#authentication) section.

### Health Check Dashboard

```bash
WEBSITES=$(curl -s "$CK_API/v2/entities/websites" "${CK_HEADERS[@]}")
echo "$WEBSITES" | jq -r '.data[] | "\(.id)\t\(.domain)\t\(.name)"'

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
URLS=("https://www.example.com/new-post/" "https://www.example.com/updated-page/")

for url in "${URLS[@]}"; do
  PAYLOAD=$(jq -n --arg url "$url" '{url: $url}')
  RESULT=$(curl -s -X POST "$CK_API/v1/check_url" "${CK_HEADERS[@]}" -d "$PAYLOAD")
  echo "$url: $RESULT"
  sleep 0.2
done
```

## Error Handling

| Code | Meaning | Action |
|------|---------|--------|
| `200` | Success | Process response |
| `400` | Invalid URL or unknown website | Check URL includes protocol and domain |
| `401` | Invalid token | Regenerate in Account > Integration Tokens |
| `403` | ToU not accepted | Accept Reporting API ToU in Account Settings |
| `404` | Resource not found | Verify website ID |
| `422` | Malformed authorization | Use `token {key}` format |
| `429` | Rate limited | Wait 1 minute, retry |

## Key Features

- **24/7 monitoring**: Continuous crawling, change tracking with timestamps, automatic issue detection
- **Health score**: 0-1000 per page and per website
- **Log file analysis**: Bot crawl frequency (Google, Bing, OpenAI, Perplexity)
- **Integrations**: Lighthouse/CWV, Google Analytics (UA + GA4), Adobe Analytics, GSC per page
- **Segments**: Group pages for targeted monitoring and reporting
- **Custom elements**: Extract HTML elements via CSS selectors
- **Alerts**: Slack, email, Microsoft Teams notifications for SEO changes
- **WordPress plugin**: Direct integration for WordPress sites

## Setup

1. Sign up at `https://www.contentkingapp.com` (free trial available)
2. Get API token from Account > Integration Tokens
3. Store securely:

```bash
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set CONTENTKING_API_TOKEN "your_token"
```

4. Verify with [List Websites](#list-websites) endpoint.

## Related Agents

- `seo/site-crawler.md` — On-demand SEO crawling (Screaming Frog-like)
- `seo/google-search-console.md` — Search performance data
- `seo/eeat-score.md` — E-E-A-T content quality scoring
- `tools/browser/pagespeed.md` — Performance auditing
