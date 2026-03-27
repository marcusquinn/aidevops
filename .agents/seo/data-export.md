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

- **Purpose**: Export SEO ranking data to TOON format
- **Platforms**: Google Search Console, Bing Webmaster Tools, Ahrefs, DataForSEO
- **Storage**: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`
- **Commands**: `/seo-export`, `seo-export-helper.sh`

```bash
seo-export-helper.sh all example.com --days 90      # all platforms
seo-export-helper.sh gsc|bing|ahrefs|dataforseo example.com
seo-export-helper.sh exports example.com            # list exports
```

<!-- AI-CONTEXT-END -->

## Supported Platforms

| Platform | Script | Data | Auth |
|----------|--------|------|------|
| Google Search Console | `seo-export-gsc.sh` | queries, pages, clicks, impressions, CTR, position | Service account JSON |
| Bing Webmaster Tools | `seo-export-bing.sh` | queries, clicks, impressions, position | API key |
| Ahrefs | `seo-export-ahrefs.sh` | keywords, URLs, traffic, volume, difficulty, position | API key |
| DataForSEO | `seo-export-dataforseo.sh` | keywords, URLs, traffic, volume, position | Username/password |

## TOON Format

```text
domain	example.com
source	gsc
exported	2026-01-28T10:00:00Z
start_date	2025-10-30
end_date	2026-01-28
---
query	page	clicks	impressions	ctr	position	volume	difficulty
best seo tools	/blog/seo-tools	150	5000	0.03	8.2
```

Fields: `query`, `page`, `clicks`, `impressions`, `ctr`, `position`, `volume` (Ahrefs/DataForSEO only), `difficulty` (Ahrefs/DataForSEO only).

File naming: `{source}-{start-date}-{end-date}.toon` — stored under `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`.

## Platform Setup

### Google Search Console

```bash
# 1. Create service account, enable Search Console API, download JSON key
# 2. Add service account email to GSC properties
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/aidevops/gsc-credentials.json"
```

### Bing Webmaster Tools

```bash
# bing.com/webmasters → Settings → API Access → Generate API Key
export BING_WEBMASTER_API_KEY="your_key"
```

### Ahrefs

```bash
# app.ahrefs.com/user/api → Generate API key
export AHREFS_API_KEY="your_key"
```

### DataForSEO

```bash
# app.dataforseo.com → dashboard credentials
export DATAFORSEO_USERNAME="your_username"
export DATAFORSEO_PASSWORD="your_password"
```

## Usage

```bash
seo-export-helper.sh all example.com --days 90          # all platforms, 90 days
seo-export-helper.sh gsc example.com --days 30          # GSC only, 30 days
seo-export-ahrefs.sh example.com --country gb           # country-specific
seo-export-dataforseo.sh example.com --location 2276    # location code
```

After export, run analysis:

```bash
seo-analysis-helper.sh example.com [quick-wins|cannibalization]
```

See `seo/ranking-opportunities.md` for analysis documentation.

## Troubleshooting

| Issue | Check |
|-------|-------|
| No data | Credentials set? Domain verified? GSC service account has property access? |
| Rate limits | Ahrefs: 500 req/month (basic); GSC: 1200 req/min; Bing: 10k req/day; DataForSEO: subscription-based |
| Missing columns | GSC/Bing have no volume/difficulty; Ahrefs/DataForSEO have full metrics. Analysis scripts handle this automatically. |
