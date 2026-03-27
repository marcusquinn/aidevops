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
- **Auth**: API key as query param (`?api_key=...`) — store via `aidevops secret set smartlead-api-key` or `SMARTLEAD_API_KEY` env var
- **Rate limit**: 10 req/2s (built-in 0.2s delay). Adjust: `SMARTLEAD_RATE_LIMIT_DELAY=0.3`
- **Config template**: `configs/smartlead-config.json.txt`
- **Strategy doc**: `services/outreach/cold-outreach.md`

## Campaign Lifecycle

```text
1. Create campaign         → campaigns create "Name"
2. Add sequences           → sequences save <id> --json <sequences>
3. Link email accounts     → accounts add-to-campaign <id> --ids 1,2,3
4. Import leads            → leads add <id> --file leads.json
5. Configure schedule      → campaigns schedule <id> --json <schedule>
6. Configure settings      → campaigns settings <id> --json <settings>
7. Start campaign          → campaigns status <id> START
```

| Status | Description | Reversible |
|---|---|---|
| `DRAFTED` | Initial state after creation | Yes |
| `START` | Activates campaign (becomes `ACTIVE`) | Yes (pause) |
| `PAUSED` | Temporarily halts sending | Yes (start) |
| `STOPPED` | Permanently stops campaign | **No** |
| `ARCHIVED` | Hidden from active views | Yes |

## Commands Reference

### Campaigns

```bash
smartlead-helper.sh campaigns list [--client-id 5]
smartlead-helper.sh campaigns get 123
smartlead-helper.sh campaigns create "Q1 Outreach 2026" [--client-id 5]
smartlead-helper.sh campaigns status 123 START|PAUSED
smartlead-helper.sh campaigns settings 123 --json '{"max_leads_per_day": 50, "track_settings": {"track_open": true, "track_click": true}}'
smartlead-helper.sh campaigns schedule 123 --json '{"timezone": "America/New_York", "days": [1,2,3,4,5], "start_hour": "09:00", "end_hour": "17:00"}'
smartlead-helper.sh campaigns delete 123
```

### Sequences

```bash
smartlead-helper.sh sequences get 123
smartlead-helper.sh sequences save 123 --json '{"sequences": [{"id": null, "seq_number": 1, "subject": "Quick question about {{company_name}}", "email_body": "<p>Hi {{first_name}},</p>", "seq_delay_details": {"delay_in_days": 0}}, {"id": null, "seq_number": 2, "email_body": "<p>Following up...</p>", "seq_delay_details": {"delay_in_days": 3}}]}'
```

**Personalization variables**: `{{first_name}}`, `{{last_name}}`, `{{company_name}}`, `{{website}}`, `{{location}}`, `{{linkedin_profile}}`, plus any custom field name.

### Leads

```bash
smartlead-helper.sh leads add 123 --file leads.json
smartlead-helper.sh leads add 123 --file leads.json --settings '{"ignore_global_block_list": false, "ignore_duplicate_leads_in_other_campaign": true}'
smartlead-helper.sh leads list 123
smartlead-helper.sh leads get 123 789
smartlead-helper.sh leads search "contact@example.com"
smartlead-helper.sh leads update 123 789 --json '{"first_name": "Jane", "custom_fields": {"job_title": "CTO"}}'
smartlead-helper.sh leads pause 123 789
smartlead-helper.sh leads resume 123 789 [--delay-days 7]
smartlead-helper.sh leads delete 123 789
smartlead-helper.sh leads unsubscribe 123 789          # Campaign-level
smartlead-helper.sh leads unsubscribe-global 789        # Global — permanent, all campaigns
smartlead-helper.sh leads export 123 [--output file.csv]
smartlead-helper.sh leads history 123 789
```

**Lead file format** — max 400 per batch (helper auto-splits larger files):

```json
{"lead_list": [{"email": "jane@example.com", "first_name": "Jane", "last_name": "Doe", "company_name": "Acme Corp", "custom_fields": {"job_title": "VP Engineering", "industry": "SaaS"}}]}
```

### Email Accounts

```bash
smartlead-helper.sh accounts list [--offset 0 --limit 50]
smartlead-helper.sh accounts get 456
smartlead-helper.sh accounts create --json '{"from_name": "Jane Smith", "from_email": "jane@outreach.example.com", "user_name": "jane@outreach.example.com", "password": "app-password", "smtp_host": "smtp.example.com", "smtp_port": 587, "imap_host": "imap.example.com", "imap_port": 993, "warmup_enabled": true, "max_email_per_day": 100}'
smartlead-helper.sh accounts update 456 --json '{"max_email_per_day": 80, "from_name": "Jane S."}'
smartlead-helper.sh accounts delete 456
smartlead-helper.sh accounts add-to-campaign 123 --ids 456,457,458
smartlead-helper.sh accounts campaign-list 123
smartlead-helper.sh accounts remove-from-campaign 123 --ids 456,457
```

### Warmup

```bash
smartlead-helper.sh warmup configure 456 --json '{"warmup_enabled": true, "total_warmup_per_day": 15, "daily_rampup": 5, "reply_rate_percentage": 30}'
smartlead-helper.sh warmup stats 456
```

Follow the warmup ramp schedule in `services/outreach/cold-outreach.md` — start at 5-8/day, scale to 20/day over 4 weeks.

### Analytics

```bash
smartlead-helper.sh analytics campaign 123
smartlead-helper.sh analytics campaign-stats 123
smartlead-helper.sh analytics date-range 123 --start 2026-01-01 --end 2026-03-31
smartlead-helper.sh analytics overview [--start 2026-01-01 --end 2026-03-31]
```

### Webhooks

```bash
# Campaign-level
smartlead-helper.sh webhooks create 123 --json '{"name": "Reply Notification", "webhook_url": "https://example.com/hooks/smartlead", "event_types": ["LEAD_REPLIED", "LEAD_BOUNCED"]}'
smartlead-helper.sh webhooks list 123
smartlead-helper.sh webhooks delete 123 456

# Global (user-level, all campaigns)
smartlead-helper.sh webhooks global-create --json '{"webhook_url": "https://example.com/hooks/all", "association_type": 1, "name": "All Events", "event_type_map": {"SENT": true, "OPENED": true, "CLICKED": true, "REPLIED": true, "BOUNCED": true}}'
smartlead-helper.sh webhooks global-get 789
smartlead-helper.sh webhooks global-update 789 --json '{"name": "Updated Hook"}'
smartlead-helper.sh webhooks global-delete 789
```

**Webhook event types**: Campaign-level: `LEAD_REPLIED`, `LEAD_OPENED`, `LEAD_CLICKED`, `LEAD_BOUNCED`, `LEAD_UNSUBSCRIBED`. Global: `SENT`, `OPENED`, `CLICKED`, `REPLIED`, `BOUNCED`, `UNSUBSCRIBED`.

### Block List

```bash
smartlead-helper.sh blocklist add-domains --json '{"domains": ["spam.com", "invalid.org"], "source": "manual"}'
smartlead-helper.sh blocklist list-domains
smartlead-helper.sh blocklist list-emails
```

Sources: `manual`, `bounce`, `complaint`, `invalid`.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SMARTLEAD_API_KEY` | — | API key (or use gopass) |
| `SMARTLEAD_BASE_URL` | `https://server.smartlead.ai/api/v1` | API base URL |
| `SMARTLEAD_TIMEOUT` | `30` | Request timeout (seconds) |
| `SMARTLEAD_RATE_LIMIT_DELAY` | `0.2` | Delay between requests (seconds) |

<!-- AI-CONTEXT-END -->

For strategy guidance (warmup schedules, compliance, platform comparison), see `services/outreach/cold-outreach.md`.
