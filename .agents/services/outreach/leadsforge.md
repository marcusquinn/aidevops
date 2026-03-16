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

## What LeadsForge Does

LeadsForge is a B2B lead search engine that connects 500M+ contacts across multiple data sources via a natural language interface. Key capabilities:

- **ICP search**: Describe your ideal customer in plain language; get a verified lead list
- **Contact enrichment**: Resolve email, LinkedIn URL, or phone number for a known contact
- **Waterfall enrichment**: Queries multiple data sources until verified data is found
- **Company lookalikes**: Find companies similar to a given domain
- **LinkedIn followers**: Find people who follow a company's LinkedIn page
- **Export**: CSV or direct push to Salesforge for sequencing

## Commands

### Search for leads by ICP

```bash
leadsforge-helper.sh search \
  --icp "CTOs at Series A SaaS companies in the US" \
  --limit 50 \
  --output leads.json
```

With enrichment (emails + LinkedIn included in results):

```bash
leadsforge-helper.sh search \
  --icp "Marketing managers at e-commerce companies in Europe" \
  --enrich \
  --limit 25
```

### Enrich a contact

By email:

```bash
leadsforge-helper.sh enrich --email "john@example.com"
```

By LinkedIn URL:

```bash
leadsforge-helper.sh enrich --linkedin "https://linkedin.com/in/johndoe"
```

### Find company lookalikes

```bash
leadsforge-helper.sh lookalikes --domain "salesforce.com" --limit 20
```

### Find LinkedIn company page followers

```bash
leadsforge-helper.sh followers --domain "hubspot.com" --limit 50
```

### Check credit balance

```bash
leadsforge-helper.sh credits
```

### Export a saved list

```bash
leadsforge-helper.sh export --list-id "abc123" --format csv --output leads.csv
```

## Setup

```bash
# Store API key securely (run in your terminal, not in AI chat)
aidevops secret set LEADSFORGE_API_KEY

# Or export directly in shell profile
export LEADSFORGE_API_KEY=<your-key>
```

WARNING: Never paste API key values into AI chat. Run the above commands in your terminal.

## Credit Costs

| Data type | Credits |
|---|---:|
| Email address | 1 |
| LinkedIn profile URL | 1 |
| Mobile number | 10 |
| Company follower + LinkedIn URL | 1 |
| Company lookalike (per company, not per lead) | 1 |

Credits do not expire. Unused credits roll over each billing period.

## ICP Search Tips

LeadsForge accepts natural language ICP descriptions. Be specific for better results:

- Include role/title: "VP of Engineering", "Head of Marketing", "Founder"
- Include company attributes: "Series A", "50-200 employees", "publicly traded"
- Include industry: "SaaS", "e-commerce", "fintech", "healthcare"
- Include geography: "US", "Europe", "APAC", "UK"
- Combine signals: "Marketing managers at funded B2B SaaS companies in the US with 50-500 employees"

## Integration with Cold Outreach Stack

LeadsForge fits into the outreach pipeline as the lead sourcing layer:

1. **LeadsForge** → search and enrich leads (this tool)
2. **Salesforge** → multi-channel sequences (email + LinkedIn)
3. **Warmforge** → mailbox deliverability and warmup
4. **FluentCRM** → WordPress-based CRM for consent-aware lifecycle messaging

Export leads from LeadsForge directly to Salesforge via the app UI, or export to CSV for import into other tools.

## Compliance Notes

- LeadsForge data is sourced from public B2B databases — suitable for legitimate interest B2B prospecting
- Always maintain CAN-SPAM and GDPR compliance in outreach (see `cold-outreach.md`)
- Document legitimate interest basis before contacting EU/UK contacts
- Honor opt-out requests immediately and suppress future sends

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `LEADSFORGE_API_KEY` | API authentication | (required) |
| `LEADSFORGE_API_BASE` | Override API base URL | `https://api.leadsforge.ai/public` |
| `LEADSFORGE_DEFAULT_LIMIT` | Default result limit | `25` |

<!-- AI-CONTEXT-END -->

Use this document as the reference for LeadsForge lead generation tasks. For outreach strategy and compliance, pair with `cold-outreach.md`.
