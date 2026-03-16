---
description: Smartlead cold outreach API — campaigns, leads, sequences, warmup, analytics, webhooks, block list
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# Smartlead Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/smartlead-helper.sh <command> <subcommand> [options]`
- **API base**: `https://server.smartlead.ai/api/v1`
- **Auth**: API key as query parameter (`?api_key=...`)
- **Rate limit**: 10 requests per 2 seconds (built-in 0.2s delay)
- **Credential**: `aidevops secret set smartlead-api-key` or `SMARTLEAD_API_KEY` env var
- **Config template**: `configs/smartlead-config.json.txt`
- **Strategy doc**: `services/outreach/cold-outreach.md`

## Authentication

Smartlead uses API key authentication via query parameter. The key is available in the Smartlead dashboard under Settings > API Keys.

```bash
# Store API key securely (run in your terminal, not in AI chat)
aidevops secret set smartlead-api-key

# Or set as environment variable
export SMARTLEAD_API_KEY="your-key-here"
```

## Campaign Lifecycle

Typical campaign setup flow via the helper:

```text
1. Create campaign         → campaigns create "Name"
2. Add sequences           → sequences save <id> --json <sequences>
3. Link email accounts     → accounts add-to-campaign <id> --ids 1,2,3
4. Import leads            → leads add <id> --file leads.json
5. Configure schedule      → campaigns schedule <id> --json <schedule>
6. Configure settings      → campaigns settings <id> --json <settings>
7. Start campaign          → campaigns status <id> START
```

### Campaign Statuses

| Status | Description | Reversible |
|---|---|---|
| `DRAFTED` | Initial state after creation | Yes |
| `START` | Activates the campaign (becomes `ACTIVE`) | Yes (pause) |
| `PAUSED` | Temporarily halts sending | Yes (start) |
| `STOPPED` | Permanently stops the campaign | **No** |
| `ARCHIVED` | Hidden from active views | Yes |

## Commands Reference

### Campaigns

```bash
# List all campaigns
smartlead-helper.sh campaigns list
smartlead-helper.sh campaigns list --client-id 5

# Get campaign details
smartlead-helper.sh campaigns get 123

# Create a new campaign
smartlead-helper.sh campaigns create "Q1 Outreach 2026"
smartlead-helper.sh campaigns create "Client Campaign" --client-id 5

# Update campaign status
smartlead-helper.sh campaigns status 123 START
smartlead-helper.sh campaigns status 123 PAUSED

# Update campaign settings
smartlead-helper.sh campaigns settings 123 --json '{"max_leads_per_day": 50, "track_settings": {"track_open": true, "track_click": true}}'

# Set campaign schedule
smartlead-helper.sh campaigns schedule 123 --json '{"timezone": "America/New_York", "days": [1,2,3,4,5], "start_hour": "09:00", "end_hour": "17:00"}'

# Delete campaign (permanent)
smartlead-helper.sh campaigns delete 123
```

### Sequences

```bash
# Get sequences for a campaign
smartlead-helper.sh sequences get 123

# Save sequences (with A/B variants)
smartlead-helper.sh sequences save 123 --json '{
  "sequences": [
    {
      "id": null,
      "seq_number": 1,
      "subject": "Quick question about {{company_name}}",
      "email_body": "<p>Hi {{first_name}},</p><p>...</p>",
      "seq_delay_details": {"delay_in_days": 0}
    },
    {
      "id": null,
      "seq_number": 2,
      "email_body": "<p>Following up on my previous email...</p>",
      "seq_delay_details": {"delay_in_days": 3}
    }
  ]
}'
```

**Personalization variables**: `{{first_name}}`, `{{last_name}}`, `{{company_name}}`, `{{website}}`, `{{location}}`, `{{linkedin_profile}}`, plus any custom field name.

### Leads

```bash
# Add leads from JSON file (auto-batches at 400 per request)
smartlead-helper.sh leads add 123 --file leads.json

# Add leads with import settings
smartlead-helper.sh leads add 123 --file leads.json --settings '{"ignore_global_block_list": false, "ignore_duplicate_leads_in_other_campaign": true}'

# List campaign leads
smartlead-helper.sh leads list 123

# Get specific lead
smartlead-helper.sh leads get 123 789

# Search lead by email (global)
smartlead-helper.sh leads search "contact@example.com"

# Update lead details
smartlead-helper.sh leads update 123 789 --json '{"first_name": "Jane", "custom_fields": {"job_title": "CTO"}}'

# Pause/resume lead
smartlead-helper.sh leads pause 123 789
smartlead-helper.sh leads resume 123 789
smartlead-helper.sh leads resume 123 789 --delay-days 7

# Delete lead from campaign
smartlead-helper.sh leads delete 123 789

# Unsubscribe (campaign-level)
smartlead-helper.sh leads unsubscribe 123 789

# Unsubscribe (global — permanent, all campaigns)
smartlead-helper.sh leads unsubscribe-global 789

# Export leads as CSV
smartlead-helper.sh leads export 123
smartlead-helper.sh leads export 123 --output campaign-leads.csv

# View lead message history
smartlead-helper.sh leads history 123 789
```

**Lead file format** (`leads.json`):

```json
{
  "lead_list": [
    {
      "email": "jane@example.com",
      "first_name": "Jane",
      "last_name": "Doe",
      "company_name": "Acme Corp",
      "custom_fields": {
        "job_title": "VP Engineering",
        "industry": "SaaS"
      }
    }
  ]
}
```

Maximum 400 leads per batch. The helper auto-splits larger files into batches.

### Email Accounts

```bash
# List all email accounts
smartlead-helper.sh accounts list
smartlead-helper.sh accounts list --offset 0 --limit 50

# Get account details
smartlead-helper.sh accounts get 456

# Create SMTP email account
smartlead-helper.sh accounts create --json '{
  "from_name": "Jane Smith",
  "from_email": "jane@outreach.example.com",
  "user_name": "jane@outreach.example.com",
  "password": "app-password",
  "smtp_host": "smtp.example.com",
  "smtp_port": 587,
  "imap_host": "imap.example.com",
  "imap_port": 993,
  "warmup_enabled": true,
  "max_email_per_day": 100
}'

# Update account settings
smartlead-helper.sh accounts update 456 --json '{"max_email_per_day": 80, "from_name": "Jane S."}'

# Delete account
smartlead-helper.sh accounts delete 456

# Add accounts to campaign
smartlead-helper.sh accounts add-to-campaign 123 --ids 456,457,458

# List campaign email accounts
smartlead-helper.sh accounts campaign-list 123

# Remove accounts from campaign
smartlead-helper.sh accounts remove-from-campaign 123 --ids 456,457
```

### Warmup

```bash
# Configure warmup for an email account
smartlead-helper.sh warmup configure 456 --json '{
  "warmup_enabled": true,
  "total_warmup_per_day": 15,
  "daily_rampup": 5,
  "reply_rate_percentage": 30
}'

# Get warmup statistics (last 7 days)
smartlead-helper.sh warmup stats 456
```

Follow the warmup ramp schedule in `services/outreach/cold-outreach.md` — start at 5-8/day, scale to 20/day over 4 weeks.

### Analytics

```bash
# Campaign-level analytics (top-level)
smartlead-helper.sh analytics campaign 123

# Campaign statistics (email-level detail)
smartlead-helper.sh analytics campaign-stats 123

# Analytics by date range
smartlead-helper.sh analytics date-range 123 --start 2026-01-01 --end 2026-03-31

# Global overview (all campaigns)
smartlead-helper.sh analytics overview
smartlead-helper.sh analytics overview --start 2026-01-01 --end 2026-03-31
```

### Webhooks

```bash
# Create campaign webhook
smartlead-helper.sh webhooks create 123 --json '{
  "name": "Reply Notification",
  "webhook_url": "https://example.com/hooks/smartlead",
  "event_types": ["LEAD_REPLIED", "LEAD_BOUNCED"]
}'

# List campaign webhooks
smartlead-helper.sh webhooks list 123

# Delete campaign webhook
smartlead-helper.sh webhooks delete 123 456

# Global webhooks (user-level, all campaigns)
smartlead-helper.sh webhooks global-create --json '{
  "webhook_url": "https://example.com/hooks/all",
  "association_type": 1,
  "name": "All Events",
  "event_type_map": {"SENT": true, "OPENED": true, "CLICKED": true, "REPLIED": true, "BOUNCED": true}
}'

smartlead-helper.sh webhooks global-get 789
smartlead-helper.sh webhooks global-update 789 --json '{"name": "Updated Hook"}'
smartlead-helper.sh webhooks global-delete 789
```

**Webhook event types**: `LEAD_REPLIED`, `LEAD_OPENED`, `LEAD_CLICKED`, `LEAD_BOUNCED`, `LEAD_UNSUBSCRIBED` (campaign-level). Global webhooks use: `SENT`, `OPENED`, `CLICKED`, `REPLIED`, `BOUNCED`, `UNSUBSCRIBED`.

### Block List

```bash
# Block domains globally (no future emails to these domains)
smartlead-helper.sh blocklist add-domains --json '{"domains": ["spam.com", "invalid.org"], "source": "manual"}'

# List blocked domains
smartlead-helper.sh blocklist list-domains

# List blocked email addresses
smartlead-helper.sh blocklist list-emails
```

Block list sources: `manual`, `bounce`, `complaint`, `invalid`.

## Rate Limiting

Smartlead enforces 10 requests per 2 seconds. The helper includes a built-in 0.2-second delay between requests. For batch operations (large lead imports), the delay is applied per API call.

Adjust the delay if needed:

```bash
export SMARTLEAD_RATE_LIMIT_DELAY=0.3  # More conservative
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SMARTLEAD_API_KEY` | — | API key (or use gopass) |
| `SMARTLEAD_BASE_URL` | `https://server.smartlead.ai/api/v1` | API base URL |
| `SMARTLEAD_TIMEOUT` | `30` | Request timeout (seconds) |
| `SMARTLEAD_RATE_LIMIT_DELAY` | `0.2` | Delay between requests (seconds) |

## Integration with Cold Outreach Strategy

This helper implements the technical layer for the strategy defined in `services/outreach/cold-outreach.md`. Key alignment points:

- **Warmup ramp**: Use `warmup configure` to match the 4-week ramp schedule (5 → 20/day)
- **Daily limits**: Set `max_email_per_day` to 100 or below per account via `accounts update`
- **Multi-mailbox rotation**: Add multiple accounts to campaigns via `accounts add-to-campaign`
- **Compliance**: Use `blocklist add-domains` for suppression; `leads unsubscribe` for opt-outs
- **Reply detection**: Configure webhooks for `LEAD_REPLIED` events to trigger handoff workflows

<!-- AI-CONTEXT-END -->

For strategy guidance (warmup schedules, compliance, platform comparison), see `services/outreach/cold-outreach.md`.
