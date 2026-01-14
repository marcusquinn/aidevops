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
  analytics_mcp_*: true
---

# Google Analytics MCP Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Google Analytics 4 (GA4) API integration
- **MCP Server**: `analytics-mcp` (official Google package via pipx)
- **Auth**: Google Cloud Application Default Credentials (ADC)
- **APIs**: Google Analytics Admin API, Google Analytics Data API
- **Capabilities**: Account summaries, property details, reports, real-time data, custom dimensions/metrics

**Environment Variables**:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/credentials.json"
export GOOGLE_PROJECT_ID="your-gcp-project-id"
```

**MCP Tools Available**:

| Category | Tools |
|----------|-------|
| **Account Info** | `get_account_summaries`, `get_property_details`, `list_google_ads_links` |
| **Reports** | `run_report`, `get_custom_dimensions_and_metrics` |
| **Real-time** | `run_realtime_report` |

<!-- AI-CONTEXT-END -->

Google Analytics MCP provides AI-assisted access to Google Analytics 4 data for website analytics, user behavior analysis, and marketing performance tracking.

## Installation

### Prerequisites

1. **Python with pipx**: Install pipx for isolated Python package management
2. **Google Cloud Project**: With Analytics APIs enabled
3. **Google Analytics Access**: User credentials with GA4 property access

### Enable Google Cloud APIs

Enable these APIs in your Google Cloud project:

- [Google Analytics Admin API](https://console.cloud.google.com/apis/library/analyticsadmin.googleapis.com)
- [Google Analytics Data API](https://console.cloud.google.com/apis/library/analyticsdata.googleapis.com)

### Configure Credentials

Set up Application Default Credentials (ADC) with the analytics readonly scope:

```bash
# Using OAuth desktop/web client
gcloud auth application-default login \
  --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform \
  --client-id-file=YOUR_CLIENT_JSON_FILE

# Or using service account impersonation
gcloud auth application-default login \
  --impersonate-service-account=SERVICE_ACCOUNT_EMAIL \
  --scopes=https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform
```

After authentication, note the credentials file path printed:
```text
Credentials saved to file: [PATH_TO_CREDENTIALS_JSON]
```

### OpenCode Configuration

Add to `~/.config/opencode/opencode.json` (disabled globally for token efficiency):

```json
{
  "mcp": {
    "analytics-mcp": {
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

**Per-Agent Enablement**: Google Analytics tools are enabled via `analytics_mcp_*: true` in this subagent's `tools:` section. Main agents (`seo.md`, `marketing.md`, `sales.md`) reference this subagent for analytics operations, ensuring the MCP is only loaded when needed.

### Claude Desktop Configuration

Add to Claude Desktop MCP settings (`~/.gemini/settings.json` for Gemini):

```json
{
  "mcpServers": {
    "analytics-mcp": {
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

## Account & Property Management

### Get Account Summaries

Retrieve information about accessible Google Analytics accounts and properties:

```text
Use get_account_summaries to list all GA4 accounts and properties
the authenticated user has access to.

Returns:
- Account names and IDs
- Property names and IDs
- Property types (GA4, Universal Analytics)
```

### Get Property Details

Get detailed information about a specific GA4 property:

```text
Use get_property_details with property ID to get:
- Property display name
- Time zone
- Currency
- Industry category
- Service level
- Create/update timestamps
```

### List Google Ads Links

View Google Ads account connections for a property:

```text
Use list_google_ads_links with property ID to see:
- Linked Google Ads accounts
- Link status
- Ads personalization settings
```

## Running Reports

### Standard Reports

Run GA4 reports using the Data API:

```text
Use run_report with:
- property_id: GA4 property ID (e.g., "properties/123456789")
- date_range: Start and end dates
- dimensions: Dimensions to include (e.g., "country", "deviceCategory")
- metrics: Metrics to include (e.g., "activeUsers", "sessions")
- dimension_filter: Optional filters
- metric_filter: Optional metric filters
- order_bys: Sort order
- limit: Row limit
```

### Common Report Examples

**Traffic Overview**:
```text
run_report with:
- dimensions: ["date"]
- metrics: ["activeUsers", "sessions", "screenPageViews"]
- date_range: last 30 days
```

**Top Pages**:
```text
run_report with:
- dimensions: ["pagePath", "pageTitle"]
- metrics: ["screenPageViews", "averageSessionDuration"]
- order_by: screenPageViews descending
- limit: 20
```

**Traffic Sources**:
```text
run_report with:
- dimensions: ["sessionSource", "sessionMedium"]
- metrics: ["sessions", "activeUsers", "conversions"]
```

**Geographic Distribution**:
```text
run_report with:
- dimensions: ["country", "city"]
- metrics: ["activeUsers", "sessions"]
```

**Device Breakdown**:
```text
run_report with:
- dimensions: ["deviceCategory", "operatingSystem"]
- metrics: ["activeUsers", "sessions"]
```

### Custom Dimensions & Metrics

Retrieve custom dimension and metric definitions:

```text
Use get_custom_dimensions_and_metrics with property ID to get:
- Custom dimension names and scopes
- Custom metric names and types
- Parameter names for implementation
```

## Real-time Analytics

### Real-time Reports

Get live data about current website activity:

```text
Use run_realtime_report with:
- property_id: GA4 property ID
- dimensions: Real-time dimensions (e.g., "country", "deviceCategory")
- metrics: Real-time metrics (e.g., "activeUsers")
```

### Real-time Use Cases

**Current Active Users**:
```text
run_realtime_report with:
- metrics: ["activeUsers"]
```

**Active Users by Page**:
```text
run_realtime_report with:
- dimensions: ["unifiedScreenName"]
- metrics: ["activeUsers"]
```

**Active Users by Source**:
```text
run_realtime_report with:
- dimensions: ["sessionSource"]
- metrics: ["activeUsers"]
```

## SEO Integration

### Search Performance Correlation

Combine GA4 data with Google Search Console for comprehensive SEO analysis:

1. **Traffic Analysis**: Use GA4 for on-site behavior metrics
2. **Search Performance**: Use GSC for search impressions and clicks
3. **Correlation**: Match landing pages between both data sources

### Content Performance

Analyze content effectiveness for SEO:

```text
run_report with:
- dimensions: ["landingPage", "sessionSource"]
- metrics: ["sessions", "bounceRate", "averageSessionDuration", "conversions"]
- dimension_filter: sessionSource = "google"
```

## Marketing Integration

### Campaign Performance

Track marketing campaign effectiveness:

```text
run_report with:
- dimensions: ["sessionCampaignName", "sessionSource", "sessionMedium"]
- metrics: ["sessions", "activeUsers", "conversions", "totalRevenue"]
```

### Conversion Analysis

Analyze conversion funnels and goals:

```text
run_report with:
- dimensions: ["eventName"]
- metrics: ["eventCount", "conversions"]
- dimension_filter: eventName matches conversion events
```

### Audience Insights

Understand audience demographics and behavior:

```text
run_report with:
- dimensions: ["userAgeBracket", "userGender"]
- metrics: ["activeUsers", "sessions", "conversions"]
```

## Sales Integration

### E-commerce Analytics

Track sales and revenue metrics:

```text
run_report with:
- dimensions: ["itemName", "itemCategory"]
- metrics: ["itemRevenue", "itemsPurchased", "itemsViewed"]
```

### Lead Generation

Track lead generation performance:

```text
run_report with:
- dimensions: ["sessionSource", "sessionMedium", "landingPage"]
- metrics: ["conversions"]
- dimension_filter: eventName = "generate_lead"
```

## Best Practices

### API Usage

- Use date ranges appropriate to your analysis needs
- Limit dimensions to avoid sparse data
- Use filters to focus on relevant data
- Cache results for repeated queries

### Data Quality

- Verify property ID before running reports
- Check for data sampling in large datasets
- Consider data freshness (real-time vs. processed)
- Validate custom dimension/metric implementations

### Performance

- Use pagination for large result sets
- Batch related queries when possible
- Consider quotas and rate limits
- Use real-time API sparingly (higher cost)

## Troubleshooting

### Authentication Errors

```bash
# Verify credentials are valid
gcloud auth application-default print-access-token

# Re-authenticate if needed
gcloud auth application-default login \
  --scopes https://www.googleapis.com/auth/analytics.readonly
```

### API Not Enabled

If you receive "API not enabled" errors:

1. Go to Google Cloud Console
2. Navigate to APIs & Services > Library
3. Enable "Google Analytics Admin API"
4. Enable "Google Analytics Data API"

### No Data Returned

- Verify property ID format: `properties/123456789`
- Check date range has data
- Verify dimensions/metrics are valid for GA4
- Ensure user has access to the property

### Rate Limiting

Google Analytics API has quotas:

- Requests per day per project
- Requests per minute per user
- Tokens per day per project

For high-volume usage, implement:
- Request batching
- Response caching
- Exponential backoff

## Related Documentation

- `seo.md` - SEO workflows with Google Analytics
- `marketing.md` - Marketing analytics with GA4
- `sales.md` - Sales analytics and e-commerce tracking
- `seo/google-search-console.md` - GSC integration for search data
- Google Analytics MCP: https://github.com/googleanalytics/google-analytics-mcp
- GA4 Data API: https://developers.google.com/analytics/devguides/reporting/data/v1
- GA4 Admin API: https://developers.google.com/analytics/devguides/config/admin/v1
