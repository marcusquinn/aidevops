---
description: Semrush SEO data via Analytics API v3 (no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# Semrush SEO Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Domain analytics, keyword research, backlink analysis, competitor research, position tracking, site audit
- **API**: REST at `https://api.semrush.com/` (Analytics v3) and `https://api.semrush.com/management/v1/` (Projects)
- **Auth**: API key as query parameter `key=` in `~/.config/aidevops/mcp-env.sh` as `SEMRUSH_API_KEY`
- **Docs**: https://developer.semrush.com/api/
- **Response format**: CSV (semicolon-delimited) for Analytics v3
- **No MCP required** - uses curl directly (Semrush also offers an official MCP server for AI tool integration)

## Pricing

Semrush API uses a unit-based system. Each API call consumes units based on the number of result lines returned.

| Plan | API Units/Month | Included With |
|------|----------------|---------------|
| Pro | 10,000 | $139.95/mo subscription |
| Guru | 30,000 | $249.95/mo subscription |
| Business | 50,000 | $499.95/mo subscription |

Additional units can be purchased. Use `display_limit` to control unit consumption.

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/mcp-env.sh
```

## API Unit Balance

```bash
curl -s "https://api.semrush.com/management/v1/projects?key=$SEMRUSH_API_KEY" \
  -H "Accept: application/json"
```

## Analytics API v3 Endpoints

All Analytics v3 endpoints return CSV (semicolon-delimited). Use `export_columns` to select fields and `display_limit` to limit rows (saves API units).

### Domain Overview (All Databases)

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_ranks&export_columns=Db,Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com"
```

### Domain Overview (One Database)

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_rank&export_columns=Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com&database=us"
```

### Domain Organic Keywords

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic&export_columns=Ph,Po,Pp,Pd,Nq,Cp,Ur,Tr,Tc,Co,Kd&domain=example.com&database=us&display_limit=50"
```

### Domain Paid Keywords

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_adwords&export_columns=Ph,Po,Nq,Cp,Tr,Tc,Co,Ur,Ds&domain=example.com&database=us&display_limit=50"
```

### Competitors in Organic Search

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_organic&export_columns=Dn,Cr,Np,Or,Ot,Oc,Ad&domain=example.com&database=us&display_limit=20"
```

### Domain vs Domain

Compare up to 5 domains for keyword overlap:

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_domains&export_columns=Ph,Nq,Cp,Co,Kd,P0,P1,P2&domains=example.com%7Cor%7C*%7Ccompetitor1.com%7Cor%7C*%7Ccompetitor2.com%7Cor%7C*&database=us&display_limit=50"
```

### Backlinks Overview

```bash
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_overview&target=example.com&target_type=root_domain&export_columns=total,domains_num,urls_num,ips_num,follows_num,nofollows_num,texts_num,images_num"
```

### Backlinks List

```bash
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks&target=example.com&target_type=root_domain&export_columns=source_url,source_title,target_url,anchor,external_num,internal_num&display_limit=50"
```

### Referring Domains

```bash
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_refdomains&target=example.com&target_type=root_domain&export_columns=domain,domain_score,backlinks_num,first_seen,last_seen&display_limit=50"
```

### Keyword Overview (One Database)

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_this&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,In&phrase=seo+tools&database=us"
```

### Keyword Overview (All Databases)

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_all&export_columns=Db,Ph,Nq,Cp,Co,Nr&phrase=seo+tools"
```

### Related Keywords

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_related&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,Rr&phrase=seo+tools&database=us&display_limit=50"
```

### Broad Match Keywords

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_fullsearch&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd&phrase=seo+tools&database=us&display_limit=50"
```

### Keyword Difficulty

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_kdi&export_columns=Ph,Kd&phrase=seo+tools&database=us"
```

### Organic Results for Keyword

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_organic&export_columns=Dn,Ur,Fk,Fp,Po&phrase=seo+tools&database=us&display_limit=20"
```

### Domain Organic Pages

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_unique&export_columns=Ur,Pc,Tg&domain=example.com&database=us&display_limit=50"
```

## Parameters

| Param | Description | Values | Required |
|-------|-------------|--------|----------|
| `key` | API key | Your Semrush API key | Yes |
| `type` | Report type | See endpoint examples | Yes |
| `domain` | Domain to analyze | `example.com` | For domain reports |
| `phrase` | Keyword to analyze | `seo+tools` (URL-encoded) | For keyword reports |
| `database` | Regional database | `us`, `uk`, `de`, `fr`, etc. (142 databases) | For single-db reports |
| `export_columns` | Fields to return | Comma-separated column codes | Yes |
| `display_limit` | Max result rows | `10`, `50`, `100` (saves API units) | No |
| `display_offset` | Pagination offset | `0`, `50`, `100` | No |
| `display_sort` | Sort order | `tr_desc`, `nq_desc`, `po_asc` | No |
| `display_filter` | Filter results | URL-encoded filter string | No |
| `target` | Backlink target | `example.com` | For backlink reports |
| `target_type` | Target scope | `root_domain`, `domain`, `url` | For backlink reports |

## Common Column Codes

| Code | Description |
|------|-------------|
| `Ph` | Keyword |
| `Po` | Position |
| `Pp` | Previous position |
| `Pd` | Position difference |
| `Nq` | Search volume (monthly) |
| `Cp` | CPC (USD) |
| `Co` | Competition (0-1) |
| `Kd` | Keyword difficulty (0-100) |
| `Tr` | Traffic (estimated) |
| `Tc` | Traffic cost (estimated) |
| `Ur` | URL |
| `Dn` | Domain |
| `Rk` | Semrush rank |
| `Or` | Organic keywords count |
| `Ot` | Organic traffic |
| `Oc` | Organic traffic cost |
| `Ad` | Paid keywords count |
| `At` | Paid traffic |
| `Ac` | Paid traffic cost |
| `In` | Search intent (0=Commercial, 1=Informational, 2=Navigational, 3=Transactional) |

## Filters

Filters use the format: `column|condition|value`. Multiple filters are joined with `|or|` or `|and|`. URL-encode the filter string.

| Condition | Meaning |
|-----------|---------|
| `Gt` | Greater than |
| `Lt` | Less than |
| `Eq` | Equal to |
| `Co` | Contains |
| `Bw` | Begins with |
| `Ew` | Ends with |

Example: keywords with volume > 1000:

```bash
# Filter: Nq|Gt|1000
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic&export_columns=Ph,Po,Nq,Cp,Kd&domain=example.com&database=us&display_limit=50&display_filter=%2B%7CNq%7CGt%7C1000"
```

## Comparison with Ahrefs

| Feature | Semrush | Ahrefs |
|---------|---------|--------|
| Auth | Query param `key=` | Bearer token header |
| Response | CSV (semicolon) | JSON |
| Keyword difficulty | 0-100 scale | 0-100 scale |
| Domain vs Domain | Up to 5 domains | N/A (separate calls) |
| Position tracking | Via Projects API | N/A via API |
| Site audit | Via Projects API | N/A via API |
| Pricing | Unit-based (included with subscription) | Subscription-based |

## Setup

Get API key from Semrush account > Subscription Info > API Units tab, and add to `~/.config/aidevops/mcp-env.sh`:

```bash
export SEMRUSH_API_KEY="your_key_here"
```
