---
description: Reverse tech stack lookup — find websites using a specific technology
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Tech Stack - Reverse Technology Lookup Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Find websites using a specific technology (BuiltWith "Technology Usage" equivalent)
- **Helper**: `~/.aidevops/agents/scripts/tech-stack-helper.sh`

**Data Sources**:

| Provider | Free Tier | Paid Tier | Best For |
|----------|-----------|-----------|----------|
| **HTTP Archive** (BigQuery) | 1TB/month free | $5/TB | Per-site tech detection, CrUX rank data |
| **Wappalyzer** (via HTTP Archive) | Included above | N/A | Adoption/deprecation trends, categories |
| **BuiltWith** API | Limited | $295/mo+ | Real-time data, detailed profiles |

<!-- AI-CONTEXT-END -->

## Commands

```bash
# Find websites using a technology
tech-stack-helper.sh reverse WordPress --limit 50 --traffic top10k
tech-stack-helper.sh reverse React --region uk --format table
tech-stack-helper.sh reverse Shopify --keywords ecommerce,fashion

# Technology metadata and adoption trends
tech-stack-helper.sh info WordPress --detections

# Browse available categories
tech-stack-helper.sh categories --format table

# Trending technologies
tech-stack-helper.sh trending --direction adopted --limit 30
tech-stack-helper.sh trending --direction deprecated

# Cache management
tech-stack-helper.sh cache status
tech-stack-helper.sh cache clear
```

## Reverse Lookup Options

| Flag | Description | Example |
|------|-------------|---------|
| `--limit, -n` | Max results (default: 25, max: 1000) | `--limit 100` |
| `--traffic, -t` | Filter by CrUX rank tier | `--traffic top10k` |
| `--keywords, -k` | Filter URLs by terms (comma-separated) | `--keywords blog,news` |
| `--region, -r` | Filter by region (maps to TLD) | `--region uk` |
| `--industry, -i` | Filter by industry keyword | `--industry healthcare` |
| `--format, -f` | Output: json, table, csv | `--format table` |
| `--provider, -p` | Provider: auto, httparchive, builtwith | `--provider builtwith` |
| `--client` | HTTP Archive client: desktop, mobile | `--client mobile` |
| `--date` | Specific crawl date | `--date 2025-12-01` |
| `--no-cache` | Force fresh query | `--no-cache` |

## Traffic Tiers

The `--traffic` flag maps to CrUX popularity rank from HTTP Archive:

| Tier | Rank Range | Description |
|------|-----------|-------------|
| `top1k` | 1-1,000 | Top 1K most popular origins |
| `top10k` | 1-10,000 | Top 10K |
| `top100k` | 1-100,000 | Top 100K |
| `top1m` | 1-1,000,000 | Top 1M |
| `<number>` | 1-N | Custom rank threshold |

## Prerequisites

1. **Google Cloud SDK**: `brew install google-cloud-sdk`
2. **BigQuery API enabled** on a GCP project (free tier: 1TB/month)
3. **Authentication**: `gcloud auth login && gcloud config set project YOUR_PROJECT`
4. **Optional**: BuiltWith API key for fallback: `aidevops secret set BUILTWITH_API_KEY`

## Data Architecture

The primary data source is HTTP Archive's `crawl.pages` table in BigQuery:

- **Table**: `httparchive.crawl.pages` (partitioned by date, clustered by client/rank/page)
- **Technologies field**: REPEATED RECORD with `technology`, `categories[]`, `info[]`
- **Rank field**: CrUX popularity rank (lower = more popular)
- **Crawl frequency**: Monthly
- **Coverage**: Millions of URLs with Wappalyzer-detected technologies

Supplementary data from `httparchive.wappalyzer`:

- **tech_detections**: Aggregated adoption/deprecation counts per technology per month
- **technologies**: Technology metadata (categories, website, description, SaaS/OSS flags)
- **categories**: Category names and descriptions

## Caching

Results are cached in `~/.aidevops/.agent-workspace/work/tech-stack/cache/`:

- Default TTL: 30 days (HTTP Archive data changes monthly)
- Crawl date cache: 7 days
- Trending data cache: 7 days
- Use `--no-cache` to force fresh queries
- Use `cache clear` to purge all cached data

## Region Mapping

The `--region` flag maps country codes/names to TLDs for URL filtering:

| Region | TLD | Region | TLD |
|--------|-----|--------|-----|
| uk/gb | .co.uk | de | .de |
| fr | .fr | jp | .jp |
| au | .com.au | ca | .ca |
| br | .com.br | in | .in |
| it | .it | es | .es |
| nl | .nl | se | .se |
| no | .no | dk | .dk |
| fi | .fi | pl | .pl |
| ru | .ru | kr | .kr |
| cn | .cn | us | .com |
