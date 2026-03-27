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

- **API**: `https://api.semrush.com/` (Analytics v3), `https://api.semrush.com/management/v1/` (Projects)
- **Auth**: `key=` query param — store as `SEMRUSH_API_KEY` in `~/.config/aidevops/credentials.sh`
- **Response**: CSV (semicolon-delimited) for Analytics v3
- **Docs**: https://developer.semrush.com/api/
- **Pricing**: Unit-based (Pro 10k/mo, Guru 30k/mo, Business 50k/mo). Use `display_limit` to control consumption.
- **No MCP required** — uses curl directly

## Auth + Unit Balance

```bash
source ~/.config/aidevops/credentials.sh
# Check unit balance:
curl -s "https://api.semrush.com/management/v1/projects?key=$SEMRUSH_API_KEY" -H "Accept: application/json"
```

## Domain Reports

```bash
# Overview — all databases
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_ranks&export_columns=Db,Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com"

# Overview — single database
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_rank&export_columns=Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com&database=us"

# Organic keywords
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic&export_columns=Ph,Po,Pp,Pd,Nq,Cp,Ur,Tr,Tc,Co,Kd&domain=example.com&database=us&display_limit=50"

# Paid keywords
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_adwords&export_columns=Ph,Po,Nq,Cp,Tr,Tc,Co,Ur,Ds&domain=example.com&database=us&display_limit=50"

# Organic competitors
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_organic&export_columns=Dn,Cr,Np,Or,Ot,Oc,Ad&domain=example.com&database=us&display_limit=20"

# Domain vs domain (up to 5, pipe-separated with %7C)
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_domains&export_columns=Ph,Nq,Cp,Co,Kd,P0,P1,P2&domains=example.com%7Cor%7C*%7Ccompetitor1.com%7Cor%7C*&database=us&display_limit=50"

# Top organic pages
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_unique&export_columns=Ur,Pc,Tg&domain=example.com&database=us&display_limit=50"
```

## Backlink Reports

```bash
# Overview
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_overview&target=example.com&target_type=root_domain&export_columns=total,domains_num,urls_num,ips_num,follows_num,nofollows_num,texts_num,images_num"

# Backlinks list
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks&target=example.com&target_type=root_domain&export_columns=source_url,source_title,target_url,anchor,external_num,internal_num&display_limit=50"

# Referring domains
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_refdomains&target=example.com&target_type=root_domain&export_columns=domain,domain_score,backlinks_num,first_seen,last_seen&display_limit=50"
```

## Keyword Reports

```bash
# Overview — single database
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_this&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,In&phrase=seo+tools&database=us"

# Overview — all databases
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_all&export_columns=Db,Ph,Nq,Cp,Co,Nr&phrase=seo+tools"

# Related keywords
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_related&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,Rr&phrase=seo+tools&database=us&display_limit=50"

# Broad match
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_fullsearch&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd&phrase=seo+tools&database=us&display_limit=50"

# Keyword difficulty
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_kdi&export_columns=Ph,Kd&phrase=seo+tools&database=us"

# Organic SERP results
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_organic&export_columns=Dn,Ur,Fk,Fp,Po&phrase=seo+tools&database=us&display_limit=20"
```

## Parameters

| Param | Description |
|-------|-------------|
| `key` | API key (required) |
| `type` | Report type (required) |
| `domain` | Domain to analyze (`example.com`) |
| `phrase` | Keyword (`seo+tools`, URL-encoded) |
| `database` | Regional DB: `us`, `uk`, `de`, `fr`, etc. (142 total) |
| `export_columns` | Comma-separated column codes (required) |
| `display_limit` | Max rows — saves API units |
| `display_offset` | Pagination offset |
| `display_sort` | Sort: `tr_desc`, `nq_desc`, `po_asc` |
| `display_filter` | URL-encoded filter string |
| `target` | Backlink target domain/URL |
| `target_type` | `root_domain`, `domain`, `url` |

## Column Codes

| Code | Description |
|------|-------------|
| `Ph` | Keyword |
| `Po` / `Pp` / `Pd` | Position / Previous / Difference |
| `Nq` | Search volume (monthly) |
| `Cp` | CPC (USD) |
| `Co` | Competition (0–1) |
| `Kd` | Keyword difficulty (0–100) |
| `Tr` / `Tc` | Traffic / Traffic cost (estimated) |
| `Ur` / `Dn` | URL / Domain |
| `Rk` | Semrush rank |
| `Or` / `Ot` / `Oc` | Organic keywords / traffic / cost |
| `Ad` / `At` / `Ac` | Paid keywords / traffic / cost |
| `In` | Search intent (0=Commercial, 1=Informational, 2=Navigational, 3=Transactional) |

## Filters

Format: `column|condition|value`. Join multiple with `|or|` or `|and|`. URL-encode the string.

Conditions: `Gt` (>), `Lt` (<), `Eq` (=), `Co` (contains), `Bw` (begins with), `Ew` (ends with)

```bash
# Keywords with volume > 1000 (filter: Nq|Gt|1000)
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic&export_columns=Ph,Po,Nq,Cp,Kd&domain=example.com&database=us&display_limit=50&display_filter=%2B%7CNq%7CGt%7C1000"
```

## vs Ahrefs

| | Semrush | Ahrefs |
|-|---------|--------|
| Auth | `key=` query param | Bearer token header |
| Response | CSV (semicolon) | JSON |
| Domain vs Domain | Up to 5 | Separate calls |
| Position tracking | Projects API | N/A |
| Site audit | Projects API | N/A |

## Setup

Get API key: Semrush account → Subscription Info → API Units tab. Add to `~/.config/aidevops/credentials.sh`:

```bash
export SEMRUSH_API_KEY="your_key_here"
```
