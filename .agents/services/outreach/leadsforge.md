---
description: LeadsForge B2B lead search and enrichment — ICP search, contact enrichment, lookalikes, LinkedIn followers
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# LeadsForge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `leadsforge-helper.sh <command> [options]`
- **API base**: `https://api.leadsforge.ai/public/`
- **Credentials**: `aidevops secret set LEADSFORGE_API_KEY` (gopass) or `export LEADSFORGE_API_KEY=<key>`
- **API key location**: https://app.leadsforge.ai/settings/api
- **Free tier**: 100 credits on signup; credits never expire
- **Capabilities**: ICP search (500M+ contacts, natural language), contact enrichment (waterfall), company lookalikes, LinkedIn followers, CSV/Salesforge export
- **Stack**: LeadsForge (search/enrich) → Salesforge (sequences) → Warmforge (deliverability) → FluentCRM (lifecycle)

## Credit Costs

| Data type | Credits |
|---|---:|
| Email address | 1 |
| LinkedIn profile URL | 1 |
| Mobile number | 10 |
| Company follower + LinkedIn URL | 1 |
| Company lookalike (per company) | 1 |

## Commands

### Search by ICP

Be specific: include role, company attributes, industry, geography.

```bash
leadsforge-helper.sh search \
  --icp "CTOs at Series A SaaS companies in the US" \
  --limit 50 \
  --output leads.json

# With enrichment (emails + LinkedIn included):
leadsforge-helper.sh search \
  --icp "Marketing managers at e-commerce companies in Europe" \
  --enrich \
  --limit 25
```

### Enrich a contact

```bash
leadsforge-helper.sh enrich --email "john@example.com"
leadsforge-helper.sh enrich --linkedin "https://linkedin.com/in/johndoe"
```

### Other commands

```bash
leadsforge-helper.sh lookalikes --domain "salesforce.com" --limit 20
leadsforge-helper.sh followers --domain "hubspot.com" --limit 50
leadsforge-helper.sh credits
leadsforge-helper.sh export --list-id "abc123" --format csv --output leads.csv
```

## Compliance

- Data sourced from public B2B databases — suitable for legitimate interest prospecting
- Maintain CAN-SPAM and GDPR compliance (see `cold-outreach.md`)
- Document legitimate interest basis before contacting EU/UK contacts; honor opt-outs immediately

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `LEADSFORGE_API_KEY` | API authentication | (required) |
| `LEADSFORGE_API_BASE` | Override API base URL | `https://api.leadsforge.ai/public` |
| `LEADSFORGE_DEFAULT_LIMIT` | Default result limit | `25` |

<!-- AI-CONTEXT-END -->
