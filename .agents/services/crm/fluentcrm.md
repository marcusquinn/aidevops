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
- **Capabilities**: Contacts, Tags, Lists, Campaigns, Automations, Email Templates, Webhooks, Smart Links

**Environment Variables**:

```bash
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

**MCP Tools Available**:

| Category | Tools |
|----------|-------|
| **Contacts** | `fluentcrm_list_contacts`, `fluentcrm_get_contact`, `fluentcrm_find_contact_by_email`, `fluentcrm_create_contact`, `fluentcrm_update_contact`, `fluentcrm_delete_contact` |
| **Tags** | `fluentcrm_list_tags`, `fluentcrm_create_tag`, `fluentcrm_delete_tag`, `fluentcrm_attach_tag_to_contact`, `fluentcrm_detach_tag_from_contact` |
| **Lists** | `fluentcrm_list_lists`, `fluentcrm_create_list`, `fluentcrm_delete_list`, `fluentcrm_attach_contact_to_list`, `fluentcrm_detach_contact_from_list` |
| **Campaigns** | `fluentcrm_list_campaigns`, `fluentcrm_create_campaign`, `fluentcrm_pause_campaign`, `fluentcrm_resume_campaign`, `fluentcrm_delete_campaign` |
| **Templates** | `fluentcrm_list_email_templates`, `fluentcrm_create_email_template` |
| **Automations** | `fluentcrm_list_automations`, `fluentcrm_create_automation` |
| **Webhooks** | `fluentcrm_list_webhooks`, `fluentcrm_create_webhook` |
| **Smart Links** | `fluentcrm_list_smart_links`, `fluentcrm_create_smart_link`, `fluentcrm_generate_smart_link_shortcode` |
| **Reports** | `fluentcrm_dashboard_stats`, `fluentcrm_custom_fields` |

<!-- AI-CONTEXT-END -->

FluentCRM is a self-hosted WordPress CRM and email marketing automation plugin. This MCP integration enables AI-assisted contact management, campaign creation, and marketing automation.

## Installation

### MCP Server Setup

**Note**: The FluentCRM MCP server is not published to npm. It requires cloning and building locally from GitHub.

```bash
# Clone and build the MCP server
mkdir -p ~/.local/share/mcp-servers
cd ~/.local/share/mcp-servers
git clone https://github.com/netflyapp/fluentcrm-mcp-server.git
cd fluentcrm-mcp-server
npm install
npm run build

# Verify build succeeded
ls dist/fluentcrm-mcp-server.js
```

### OpenCode Configuration

Add to `~/.config/opencode/opencode.json` (disabled globally for token efficiency):

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

**Per-Agent Enablement**: FluentCRM tools are enabled via `fluentcrm_*: true` in this subagent's `tools:` section. Main agents (`sales.md`, `marketing.md`) reference this subagent for CRM operations, ensuring the MCP is only loaded when needed.

### Claude Desktop Configuration

Add to Claude Desktop MCP settings:

```json
{
  "mcpServers": {
    "fluentcrm": {
      "command": "node",
      "args": ["~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
      "env": {
        "FLUENTCRM_API_URL": "https://your-domain.com/wp-json/fluent-crm/v2",
        "FLUENTCRM_API_USERNAME": "your_username",
        "FLUENTCRM_API_PASSWORD": "your_application_password"
      }
    }
  }
}
```

### WordPress Setup

1. **Install FluentCRM** plugin on your WordPress site
2. **Create Application Password**:
   - Go to Users > Your Profile
   - Scroll to "Application Passwords"
   - Create new password for API access
3. **Enable REST API** (usually enabled by default)
4. **Configure CORS** if accessing from different domain

## Contact Management

### List Contacts

```text
Use fluentcrm_list_contacts to get all contacts
Parameters:
- page: Page number (default: 1)
- per_page: Records per page (default: 10)
- search: Search by email/name
```

### Create Contact

```text
Use fluentcrm_create_contact with:
- email (required): Contact email
- first_name: First name
- last_name: Last name
- phone: Phone number
- address_line_1: Address
- city: City
- country: Country
```

### Find by Email

```text
Use fluentcrm_find_contact_by_email to search for a specific contact
```

### Update Contact

```text
Use fluentcrm_update_contact with subscriberId and fields to update
```

## Tag Management

Tags are used for segmentation and automation triggers.

### Common Tag Patterns

| Pattern | Use Case |
|---------|----------|
| `lead-source-*` | Track where leads came from |
| `interest-*` | Track product/service interests |
| `stage-*` | Sales pipeline stages |
| `campaign-*` | Campaign participation |
| `behavior-*` | User behavior tracking |

### Tag Operations

```text
# List all tags
fluentcrm_list_tags

# Create tag
fluentcrm_create_tag with title, slug, description

# Attach tag to contact
fluentcrm_attach_tag_to_contact with subscriberId and tagIds array

# Detach tag from contact
fluentcrm_detach_tag_from_contact with subscriberId and tagIds array
```

## List Management

Lists are used for organizing contacts into groups for campaigns.

### List Operations

```text
# List all lists
fluentcrm_list_lists

# Create list
fluentcrm_create_list with title, slug, description

# Add contact to list
fluentcrm_attach_contact_to_list with subscriberId and listIds array

# Remove contact from list
fluentcrm_detach_contact_from_list with subscriberId and listIds array
```

## Email Campaigns

### Campaign Workflow

1. **Create email template** with content
2. **Create campaign** with subject and recipient lists
3. **Review and schedule** campaign
4. **Monitor** delivery and engagement

### Campaign Operations

```text
# List campaigns
fluentcrm_list_campaigns

# Create campaign
fluentcrm_create_campaign with:
- title: Campaign name
- subject: Email subject line
- template_id: Email template ID
- recipient_list: Array of list IDs

# Pause/Resume campaign
fluentcrm_pause_campaign / fluentcrm_resume_campaign with campaignId
```

### Email Templates

```text
# List templates
fluentcrm_list_email_templates

# Create template
fluentcrm_create_email_template with:
- title: Template name
- subject: Default subject
- body: HTML content
```

## Marketing Automation

### Automation Funnels

FluentCRM automations (funnels) trigger actions based on events.

```text
# List automations
fluentcrm_list_automations

# Create automation
fluentcrm_create_automation with:
- title: Automation name
- description: Description
- trigger: Trigger type (e.g., 'tag_added', 'list_added', 'form_submitted')
```

### Common Automation Triggers

| Trigger | Use Case |
|---------|----------|
| `tag_added` | When tag is applied to contact |
| `list_added` | When contact joins a list |
| `form_submitted` | When form is submitted |
| `link_clicked` | When email link is clicked |
| `email_opened` | When email is opened |

## Smart Links

Smart Links are trackable URLs that can apply tags/lists when clicked.

### Smart Link Operations

```text
# Create smart link
fluentcrm_create_smart_link with:
- title: Link name
- slug: URL slug
- target_url: Destination URL
- apply_tags: Tag IDs to add on click
- apply_lists: List IDs to add on click
- remove_tags: Tag IDs to remove on click
- remove_lists: List IDs to remove on click
- auto_login: Auto-login user on click

# Generate shortcode
fluentcrm_generate_smart_link_shortcode with slug and optional linkText
```

**Note**: Smart Links API may not be available in all FluentCRM versions. Use the admin panel if API returns 404.

## Webhooks

### Webhook Configuration

```text
# List webhooks
fluentcrm_list_webhooks

# Create webhook
fluentcrm_create_webhook with:
- name: Webhook name
- url: Webhook URL
- status: 'pending' or 'subscribed'
- tags: Tag IDs to filter
- lists: List IDs to filter
```

### Webhook Events

FluentCRM can send webhooks for:

- Contact created/updated
- Tag added/removed
- List subscription changes
- Email events (sent, opened, clicked)
- Form submissions

## Reports & Analytics

### Dashboard Stats

```text
# Get dashboard statistics
fluentcrm_dashboard_stats

Returns:
- Total contacts
- New contacts (period)
- Email stats
- Campaign performance
```

### Custom Fields

```text
# List custom fields
fluentcrm_custom_fields

Returns all custom field definitions for contacts
```

## Sales Integration

### Lead Management Workflow

1. **Capture lead** via form or API
2. **Apply tags** based on source/interest
3. **Add to nurture list**
4. **Trigger automation** for follow-up
5. **Track engagement** via email opens/clicks
6. **Update tags** as lead progresses

### Example: New Lead Processing

```text
1. fluentcrm_create_contact with lead details
2. fluentcrm_attach_tag_to_contact with ['lead-new', 'source-website']
3. fluentcrm_attach_contact_to_list with nurture list ID
4. Automation triggers welcome sequence
```

## Marketing Integration

### Campaign Workflow

1. **Segment audience** using tags/lists
2. **Create email template** with content
3. **Create campaign** targeting segments
4. **Schedule or send** campaign
5. **Monitor** opens, clicks, conversions
6. **Apply tags** based on engagement

### Example: Product Launch Campaign

```text
1. fluentcrm_create_list for launch audience
2. fluentcrm_create_email_template with launch content
3. fluentcrm_create_campaign targeting launch list
4. Create automation to tag engaged contacts
```

## Best Practices

### Contact Data Quality

- Always validate email before creating contacts
- Use consistent tag naming conventions
- Regularly clean inactive contacts
- Merge duplicate contacts

### Email Deliverability

- Warm up new sending domains
- Monitor bounce rates
- Honor unsubscribe requests immediately
- Use double opt-in for marketing lists

### Automation Design

- Keep automations simple and focused
- Test automations with test contacts first
- Monitor automation performance
- Document automation logic

### GDPR Compliance

- Obtain explicit consent for marketing
- Provide easy unsubscribe options
- Honor data deletion requests
- Document consent sources

## Troubleshooting

### Authentication Errors

```bash
# Verify credentials
curl -u "username:app_password" \
  "https://your-domain.com/wp-json/fluent-crm/v2/subscribers"
```

### API Not Available

- Ensure FluentCRM plugin is active
- Check WordPress REST API is enabled
- Verify permalink settings (not "Plain")
- Check for security plugins blocking API

### Rate Limiting

FluentCRM may rate limit API requests. For bulk operations:

- Use pagination for large datasets
- Add delays between requests
- Consider batch operations where available

## Related Documentation

- `sales.md` - Sales workflows with FluentCRM
- `marketing.md` - Marketing campaigns with FluentCRM
- `services/email/ses.md` - Email delivery via SES
- FluentCRM Docs: https://fluentcrm.com/docs/
- FluentCRM REST API: https://rest-api.fluentcrm.com/
