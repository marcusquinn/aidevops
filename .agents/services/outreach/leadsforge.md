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
- **Compliance**: Public B2B data; CAN-SPAM/GDPR apply — document legitimate interest for EU/UK contacts, honor opt-outs. See `cold-outreach.md`.
- **Env vars**: `LEADSFORGE_API_KEY` (required), `LEADSFORGE_API_BASE` (override base URL), `LEADSFORGE_DEFAULT_LIMIT` (default: `25`)

## Credit Costs

| Data type | Credits |
|---|---:|
| Email address | 1 |
| LinkedIn profile URL | 1 |
| Mobile number | 10 |
| Company follower + LinkedIn URL | 1 |
| Company lookalike (per company) | 1 |

## Commands

ICP search: be specific — role, company attributes, industry, geography.

```bash
# Search by ICP
leadsforge-helper.sh search --icp "CTOs at Series A SaaS companies in the US" --limit 50 --output leads.json
leadsforge-helper.sh search --icp "Marketing managers at e-commerce companies in Europe" --enrich --limit 25

# Enrich a contact
leadsforge-helper.sh enrich --email "john@example.com"
leadsforge-helper.sh enrich --linkedin "https://linkedin.com/in/johndoe"

# Other
leadsforge-helper.sh lookalikes --domain "salesforce.com" --limit 20
leadsforge-helper.sh followers --domain "hubspot.com" --limit 50
leadsforge-helper.sh credits
leadsforge-helper.sh export --list-id "abc123" --format csv --output leads.csv
```

<!-- AI-CONTEXT-END -->
