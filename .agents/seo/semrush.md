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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Semrush SEO Integration

## Quick Reference

- **API**: `https://api.semrush.com/` (Analytics v3) | `https://api.semrush.com/management/v1/` (Projects)
- **Auth**: `key=` query param — `SEMRUSH_API_KEY` in `~/.config/aidevops/credentials.sh`; `source ~/.config/aidevops/credentials.sh`
- **Response**: CSV (semicolon-delimited). Docs: https://developer.semrush.com/api/ — no MCP required (curl direct; official MCP also available)
- **Setup**: Semrush account > Subscription Info > API Units tab; `export SEMRUSH_API_KEY="your_key_here"`
- **Pricing**: Pro 10k units/$139.95 | Guru 30k/$249.95 | Business 50k/$499.95 per month. Additional units purchasable.
- **Unit balance**: `curl -s "https://api.semrush.com/management/v1/projects?key=$SEMRUSH_API_KEY" -H "Accept: application/json"`

Use `display_limit` to control unit consumption per request.

## Endpoints

All Analytics v3 endpoints return CSV (semicolon-delimited). Use `export_columns` to select fields.

### Domain Reports

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_ranks&export_columns=Db,Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_rank&export_columns=Dn,Rk,Or,Ot,Oc,Ad,At,Ac&domain=example.com&database=us"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic&export_columns=Ph,Po,Pp,Pd,Nq,Cp,Ur,Tr,Tc,Co,Kd&domain=example.com&database=us&display_limit=50"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_adwords&export_columns=Ph,Po,Nq,Cp,Tr,Tc,Co,Ur,Ds&domain=example.com&database=us&display_limit=50"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_unique&export_columns=Ur,Pc,Tg&domain=example.com&database=us&display_limit=50"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_organic_organic&export_columns=Dn,Cr,Np,Or,Ot,Oc,Ad&domain=example.com&database=us&display_limit=20"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=domain_domains&export_columns=Ph,Nq,Cp,Co,Kd,P0,P1,P2&domains=example.com%7Cor%7C*%7Ccompetitor1.com%7Cor%7C*%7Ccompetitor2.com%7Cor%7C*&database=us&display_limit=50"
```

`domain_ranks`=all DBs overview, `domain_rank`=one DB, `domain_organic`=organic keywords, `domain_adwords`=paid keywords, `domain_organic_unique`=organic pages, `domain_organic_organic`=competitors, `domain_domains`=domain vs domain (up to 5).

### Keyword Reports

```bash
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_this&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,In&phrase=seo+tools&database=us"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_all&export_columns=Db,Ph,Nq,Cp,Co,Nr&phrase=seo+tools"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_related&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd,Rr&phrase=seo+tools&database=us&display_limit=50"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_fullsearch&export_columns=Ph,Nq,Cp,Co,Nr,Td,Kd&phrase=seo+tools&database=us&display_limit=50"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_kdi&export_columns=Ph,Kd&phrase=seo+tools&database=us"
curl -s "https://api.semrush.com/?key=$SEMRUSH_API_KEY&type=phrase_organic&export_columns=Dn,Ur,Fk,Fp,Po&phrase=seo+tools&database=us&display_limit=20"
```

`phrase_this`=one DB overview, `phrase_all`=all DBs, `phrase_related`=related keywords, `phrase_fullsearch`=broad match, `phrase_kdi`=difficulty, `phrase_organic`=organic results for keyword.

### Backlink Reports

```bash
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_overview&target=example.com&target_type=root_domain&export_columns=total,domains_num,urls_num,ips_num,follows_num,nofollows_num,texts_num,images_num"
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks&target=example.com&target_type=root_domain&export_columns=source_url,source_title,target_url,anchor,external_num,internal_num&display_limit=50"
curl -s "https://api.semrush.com/analytics/v1/?key=$SEMRUSH_API_KEY&type=backlinks_refdomains&target=example.com&target_type=root_domain&export_columns=domain,domain_score,backlinks_num,first_seen,last_seen&display_limit=50"
```

`backlinks_overview`=summary, `backlinks`=full list, `backlinks_refdomains`=referring domains.

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

Format: `column|condition|value`. Join multiple with `|or|` or `|and|`. URL-encode the filter string.

Conditions: `Gt` (greater than), `Lt` (less than), `Eq` (equal), `Co` (contains), `Bw` (begins with), `Ew` (ends with).

Example — keywords with volume > 1000 (`Nq|Gt|1000`):

```bash
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
