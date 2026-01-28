---
description: Export SEO data from multiple platforms to TOON format
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# SEO Data Export

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Export SEO ranking data from multiple platforms to a common TOON format
- **Platforms**: Google Search Console, Bing Webmaster Tools, Ahrefs, DataForSEO
- **Storage**: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`
- **Format**: TOON (tab-separated, token-efficient)
- **Commands**: `/seo-export`, `seo-export-helper.sh`

**Quick Commands**:

```bash
# Export from all platforms
seo-export-helper.sh all example.com --days 90

# Export from specific platform
seo-export-helper.sh gsc example.com
seo-export-helper.sh bing example.com
seo-export-helper.sh ahrefs example.com
seo-export-helper.sh dataforseo example.com

# List available platforms
seo-export-helper.sh list

# List exports for a domain
seo-export-helper.sh exports example.com
```

<!-- AI-CONTEXT-END -->

## Supported Platforms

| Platform | Script | Data Provided | Auth Required |
|----------|--------|---------------|---------------|
| Google Search Console | `seo-export-gsc.sh` | queries, pages, clicks, impressions, CTR, position | Service account JSON |
| Bing Webmaster Tools | `seo-export-bing.sh` | queries, clicks, impressions, position | API key |
| Ahrefs | `seo-export-ahrefs.sh` | keywords, URLs, traffic, volume, difficulty, position | API key |
| DataForSEO | `seo-export-dataforseo.sh` | keywords, URLs, traffic, volume, position | Username/password |

## TOON Format

All exports use a common TOON format for consistency:

```text
domain	example.com
source	gsc
exported	2026-01-28T10:00:00Z
start_date	2025-10-30
end_date	2026-01-28
---
query	page	clicks	impressions	ctr	position
best seo tools	/blog/seo-tools	150	5000	0.03	8.2
keyword research	/guides/keywords	89	3200	0.028	12.4
```

### Header Fields

| Field | Description |
|-------|-------------|
| `domain` | The domain being analyzed |
| `source` | Data source (gsc, bing, ahrefs, dataforseo) |
| `exported` | ISO 8601 timestamp of export |
| `start_date` | Start of date range |
| `end_date` | End of date range |

### Data Fields

| Field | Description |
|-------|-------------|
| `query` | Search query/keyword |
| `page` | Ranking URL |
| `clicks` | Click count or estimated traffic |
| `impressions` | Impression count or estimated |
| `ctr` | Click-through rate (0-1) |
| `position` | Average ranking position |
| `volume` | Monthly search volume (Ahrefs/DataForSEO only) |
| `difficulty` | Keyword difficulty (Ahrefs/DataForSEO only) |

## File Naming

Files are named with the date range they cover:

```text
{source}-{start-date}-{end-date}.toon
```

Examples:
- `gsc-2025-10-30-2026-01-28.toon`
- `ahrefs-2025-10-30-2026-01-28.toon`

## Storage Location

```text
~/.aidevops/.agent-workspace/work/seo-data/
└── example.com/
    ├── gsc-2025-10-30-2026-01-28.toon
    ├── bing-2025-10-30-2026-01-28.toon
    ├── ahrefs-2025-10-30-2026-01-28.toon
    ├── dataforseo-2025-10-30-2026-01-28.toon
    └── analysis-2026-01-28.toon
```

## Platform Setup

### Google Search Console

1. Create service account in Google Cloud Console
2. Enable Search Console API
3. Download JSON key to `~/.config/aidevops/gsc-credentials.json`
4. Add service account email to GSC properties

```bash
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/aidevops/gsc-credentials.json"
```

### Bing Webmaster Tools

1. Go to https://www.bing.com/webmasters
2. Verify your site
3. Settings → API Access → Generate API Key

```bash
export BING_WEBMASTER_API_KEY="your_key"
```

### Ahrefs

1. Go to https://app.ahrefs.com/user/api
2. Generate API key

```bash
export AHREFS_API_KEY="your_key"
```

### DataForSEO

1. Sign up at https://app.dataforseo.com/
2. Get credentials from dashboard

```bash
export DATAFORSEO_USERNAME="your_username"
export DATAFORSEO_PASSWORD="your_password"
```

## Usage Examples

### Export Last 90 Days from All Platforms

```bash
seo-export-helper.sh all example.com --days 90
```

### Export Last 30 Days from GSC Only

```bash
seo-export-helper.sh gsc example.com --days 30
```

### Export with Country-Specific Data

```bash
# Ahrefs - UK market
seo-export-ahrefs.sh example.com --country gb

# DataForSEO - Germany
seo-export-dataforseo.sh example.com --location 2276
```

### Check Available Exports

```bash
seo-export-helper.sh exports example.com
```

## Integration with Analysis

After exporting, run analysis:

```bash
# Full analysis
seo-analysis-helper.sh example.com

# Specific analysis
seo-analysis-helper.sh example.com quick-wins
seo-analysis-helper.sh example.com cannibalization
```

See `seo/ranking-opportunities.md` for analysis documentation.

## Troubleshooting

### No Data Returned

- Verify API credentials are set correctly
- Check that the domain is verified in the platform
- For GSC, ensure service account has access to the property

### API Rate Limits

- Ahrefs: 500 requests/month on basic plan
- DataForSEO: Based on subscription
- GSC: 1200 requests/minute
- Bing: 10,000 requests/day

### Missing Columns

Different platforms provide different data:
- GSC/Bing: No volume or difficulty data
- Ahrefs/DataForSEO: Full keyword metrics

The analysis scripts handle these differences automatically.
