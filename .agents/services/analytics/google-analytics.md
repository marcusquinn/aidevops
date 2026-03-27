---
description: Google Analytics MCP - GA4 reporting, account management, and real-time analytics
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  google_analytics_mcp_*: true
---

# Google Analytics MCP Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

| Item | Value |
|------|-------|
| **Type** | Google Analytics 4 (GA4) API |
| **MCP Server** | `google-analytics-mcp` (config key) / `analytics-mcp` (PyPI) |
| **Auth** | Google Cloud Application Default Credentials (ADC) |
| **APIs** | Analytics Admin API, Analytics Data API |

**Environment variables:**

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/credentials.json"
export GOOGLE_PROJECT_ID="your-gcp-project-id"
```

**MCP tools:**

| Category | Tools |
|----------|-------|
| Account | `get_account_summaries`, `get_property_details`, `list_google_ads_links` |
| Reports | `run_report`, `get_custom_dimensions_and_metrics` |
| Real-time | `run_realtime_report` |

<!-- AI-CONTEXT-END -->

## Installation

**Prerequisites:** pipx, Google Cloud Project with Analytics APIs enabled, GA4 property access.

**Enable APIs** (Google Cloud Console > APIs & Services > Library):

- Google Analytics Admin API
- Google Analytics Data API

**Configure ADC:**

```bash
# OAuth desktop/web client
gcloud auth application-default login \
  --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform \
  --client-id-file=YOUR_CLIENT_JSON_FILE

# Service account impersonation
gcloud auth application-default login \
  --impersonate-service-account=SERVICE_ACCOUNT_EMAIL \
  --scopes=https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform
```

**Claude Code config** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "google-analytics-mcp": {
      "type": "local",
      "command": ["pipx", "run", "analytics-mcp"],
      "env": {
        "GOOGLE_APPLICATION_CREDENTIALS": "/path/to/credentials.json",
        "GOOGLE_PROJECT_ID": "your-project-id"
      },
      "enabled": false
    }
  }
}
```

**Gemini CLI config** (`~/.gemini/settings.json`):

```json
{
  "mcpServers": {
    "google-analytics-mcp": {
      "command": "pipx",
      "args": ["run", "analytics-mcp"],
      "env": {
        "GOOGLE_APPLICATION_CREDENTIALS": "/path/to/credentials.json",
        "GOOGLE_PROJECT_ID": "your-project-id"
      }
    }
  }
}
```

**Per-agent enablement:** Enabled via `google_analytics_mcp_*: true` in this subagent's `tools:` section. Main agents (`seo.md`, `marketing.md`, `sales.md`) reference this subagent — MCP only loads when needed.

## Account & Property Management

| Tool | Returns |
|------|---------|
| `get_account_summaries` | Account/property names and IDs, property types |
| `get_property_details` | Display name, timezone, currency, industry, service level, timestamps |
| `list_google_ads_links` | Linked Ads accounts, link status, ads personalization settings |

## Reports

**`run_report` parameters:** `property_id` (e.g. `properties/123456789`), `date_range`, `dimensions`, `metrics`, `dimension_filter`, `metric_filter`, `order_bys`, `limit`

**Common report recipes:**

| Use case | dimensions | metrics |
|----------|-----------|---------|
| Traffic overview | `["date"]` | `["activeUsers", "sessions", "screenPageViews"]` |
| Top pages | `["pagePath", "pageTitle"]` | `["screenPageViews", "averageSessionDuration"]` |
| Traffic sources | `["sessionSource", "sessionMedium"]` | `["sessions", "activeUsers", "conversions"]` |
| Geographic | `["country", "city"]` | `["activeUsers", "sessions"]` |
| Device breakdown | `["deviceCategory", "operatingSystem"]` | `["activeUsers", "sessions"]` |
| SEO content | `["landingPage", "sessionSource"]` | `["sessions", "bounceRate", "averageSessionDuration", "conversions"]` + filter `sessionSource = "google"` |
| Campaign | `["sessionCampaignName", "sessionSource", "sessionMedium"]` | `["sessions", "activeUsers", "conversions", "totalRevenue"]` |
| Conversions | `["eventName"]` | `["eventCount", "conversions"]` |
| Audience | `["userAgeBracket", "userGender"]` | `["activeUsers", "sessions", "conversions"]` |
| E-commerce | `["itemName", "itemCategory"]` | `["itemRevenue", "itemsPurchased", "itemsViewed"]` |
| Lead gen | `["sessionSource", "sessionMedium", "landingPage"]` | `["conversions"]` + filter `eventName = "generate_lead"` |

**Custom dimensions/metrics:** `get_custom_dimensions_and_metrics` — returns names, scopes, types, parameter names.

## Real-time Reports

**`run_realtime_report` parameters:** `property_id`, `dimensions`, `metrics`

| Use case | dimensions | metrics |
|----------|-----------|---------|
| Active users now | — | `["activeUsers"]` |
| By page | `["unifiedScreenName"]` | `["activeUsers"]` |
| By source | `["sessionSource"]` | `["activeUsers"]` |

## Best Practices

| Area | Rules |
|------|-------|
| **API usage** | Match date range to analysis; limit dimensions to avoid sparse data; cache repeated queries |
| **Data quality** | Verify property ID; check for sampling in large datasets; validate custom dimension implementations |
| **Performance** | Paginate large results; batch related queries; use real-time API sparingly (higher quota cost) |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Auth error | `gcloud auth application-default print-access-token` to verify; re-run `gcloud auth application-default login` |
| API not enabled | Cloud Console > APIs & Services > Library > enable Admin API + Data API |
| No data returned | Verify `properties/123456789` format; check date range; confirm user has property access |
| Rate limiting | Implement request batching, response caching, exponential backoff |

## Related

- `seo.md`, `marketing.md`, `sales.md` — domain agents that invoke this subagent
- `seo/google-search-console.md` — GSC integration for search data
- [Google Analytics MCP](https://github.com/googleanalytics/google-analytics-mcp)
- [GA4 Data API](https://developers.google.com/analytics/devguides/reporting/data/v1)
- [GA4 Admin API](https://developers.google.com/analytics/devguides/config/admin/v1)
