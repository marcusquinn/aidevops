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
- **Pricing**: Credit-based — 1 email = 1 credit, 1 LinkedIn URL = 1 credit, 1 mobile = 10 credits
- **Free tier**: 100 credits on signup
- **Capabilities**: ICP search (500M+ contacts, natural language), contact enrichment (waterfall), company lookalikes, LinkedIn followers, CSV/Salesforge export

## Commands

### Search for leads by ICP

```bash
leadsforge-helper.sh search \
  --icp "CTOs at Series A SaaS companies in the US" \
  --limit 50 \
  --output leads.json
```

With enrichment (emails + LinkedIn included):

```bash
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

## Setup

```bash
# Run in terminal — never paste API keys into AI chat
aidevops secret set LEADSFORGE_API_KEY
```

## Credit Costs

| Data type | Credits |
|---|---:|
| Email address | 1 |
| LinkedIn profile URL | 1 |
| Mobile number | 10 |
| Company follower + LinkedIn URL | 1 |
| Company lookalike (per company) | 1 |

Credits do not expire.

## ICP Search Tips

Be specific: include role, company attributes, industry, and geography. Example: `"Marketing managers at funded B2B SaaS companies in the US with 50-500 employees"`.

## Integration with Cold Outreach Stack

1. **LeadsForge** → search and enrich leads (this tool)
2. **Salesforge** → multi-channel sequences (email + LinkedIn)
3. **Warmforge** → mailbox deliverability and warmup
4. **FluentCRM** → WordPress-based CRM for consent-aware lifecycle messaging

## Compliance

- Data sourced from public B2B databases — suitable for legitimate interest B2B prospecting
- Maintain CAN-SPAM and GDPR compliance (see `cold-outreach.md`)
- Document legitimate interest basis before contacting EU/UK contacts
- Honor opt-out requests immediately

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `LEADSFORGE_API_KEY` | API authentication | (required) |
| `LEADSFORGE_API_BASE` | Override API base URL | `https://api.leadsforge.ai/public` |
| `LEADSFORGE_DEFAULT_LIMIT` | Default result limit | `25` |

<!-- AI-CONTEXT-END -->
