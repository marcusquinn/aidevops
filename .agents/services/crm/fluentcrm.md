---
description: FluentCRM MCP - WordPress CRM with email marketing, automation, and contact management
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  fluentcrm_*: true
---

# FluentCRM MCP Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: WordPress CRM plugin with REST API
- **MCP Server**: `fluentcrm-mcp-server` (local build from GitHub)
- **Auth**: WordPress Basic Auth (username + application password)
- **API Base**: `https://your-domain.com/wp-json/fluent-crm/v2`

**Environment Variables**:

```bash
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

**MCP Tools** (prefix `fluentcrm_`): contacts (list/get/find_by_email/create/update/delete), tags (list/create/delete/attach/detach), lists (list/create/delete/attach/detach), campaigns (list/create/pause/resume/delete), email_templates (list/create), automations (list/create), webhooks (list/create), smart_links (list/create/generate_shortcode), dashboard_stats, custom_fields.

<!-- AI-CONTEXT-END -->

## Installation

Clone and build locally (not published to npm):

```bash
mkdir -p ~/.local/share/mcp-servers && cd ~/.local/share/mcp-servers
git clone https://github.com/netflyapp/fluentcrm-mcp-server.git
cd fluentcrm-mcp-server && npm install && npm run build
ls dist/fluentcrm-mcp-server.js  # verify build
```

**OpenCode** (`~/.config/opencode/opencode.json`, disabled globally for token efficiency):

```json
{
  "mcp": {
    "fluentcrm": {
      "type": "local",
      "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && node ~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
      "enabled": false
    }
  }
}
```

**Claude Desktop**: `command: node`, `args: [".../dist/fluentcrm-mcp-server.js"]`, `env: {FLUENTCRM_API_URL, FLUENTCRM_API_USERNAME, FLUENTCRM_API_PASSWORD}`.

**Per-Agent Enablement**: FluentCRM tools enabled via `fluentcrm_*: true` in subagent `tools:` section. Main agents reference this subagent for CRM operations — MCP only loaded when needed.

**WordPress Setup**: Install FluentCRM plugin → create Application Password (Users > Profile) → ensure REST API enabled and permalinks not "Plain" → configure CORS if cross-domain.

## Tool API Reference

### Contacts

- `fluentcrm_create_contact` — required: `email`; optional: `first_name`, `last_name`, `phone`, `address_line_1`, `city`, `country`
- `fluentcrm_list_contacts` — pagination: `page`, `per_page`; filter: `search` (email/name)
- `fluentcrm_find_contact_by_email` — exact email lookup
- `fluentcrm_update_contact` — `subscriberId` + fields to update

### Campaigns

1. Create template: `fluentcrm_create_email_template` (`title`, `subject`, `body` as HTML)
2. Create campaign: `fluentcrm_create_campaign` (`title`, `subject`, `template_id`, `recipient_list` as array of list IDs)
3. Monitor: `fluentcrm_dashboard_stats`
4. Control: `fluentcrm_pause_campaign` / `fluentcrm_resume_campaign`

### Automations

`fluentcrm_create_automation` (`title`, `description`, `trigger`):

| Trigger | Fires when |
|---------|------------|
| `tag_added` | Tag applied to contact |
| `list_added` | Contact joins a list |
| `form_submitted` | Form submitted |
| `link_clicked` | Email link clicked |
| `email_opened` | Email opened |

### Smart Links

Trackable URLs that apply tags/lists on click. `fluentcrm_create_smart_link`: `target_url`, `apply_tags`/`remove_tags`, `apply_lists`/`remove_lists`, `auto_login`. Shortcode: `fluentcrm_generate_smart_link_shortcode` (`slug`, optional `linkText`).

Smart Links API may not be available in all FluentCRM versions — use admin panel if API returns 404.

### Webhooks

`fluentcrm_create_webhook`: `name`, `url`, `status` (`pending`/`subscribed`), `tags`, `lists`. Events: contact created/updated, tag added/removed, list subscription changes, email events (sent/opened/clicked), form submissions.

## Troubleshooting

**Auth errors**: `curl -u "username:app_password" "https://your-domain.com/wp-json/fluent-crm/v2/subscribers"`

**API not available**: Verify FluentCRM plugin active, REST API enabled, permalinks not "Plain", no security plugins blocking API.

**Rate limiting**: Use pagination for large datasets; add delays between requests; use batch operations where available.

## Related

- `marketing-sales.md` — Sales/marketing workflows, tag naming conventions, lead processing, best practices
- `services/email/ses.md` — Email delivery via SES
- FluentCRM Docs: <https://fluentcrm.com/docs/>
- FluentCRM REST API: <https://rest-api.fluentcrm.com/>
