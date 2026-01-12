---
name: sales
description: Sales operations and CRM - lead management, pipeline tracking, sales automation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Sales - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Sales operations, CRM management, and pipeline tracking
- **CRM Integration**: FluentCRM MCP for WordPress-based CRM

**Related Agents**:

- `marketing.md` - Lead generation and campaigns
- `content.md` - Sales collateral and proposals
- `services/accounting/quickfile.md` - Invoicing and payments
- `services/crm/fluentcrm.md` - CRM operations (detailed)

**FluentCRM MCP Tools**:

| Category | Key Tools |
|----------|-----------|
| **Contacts** | `fluentcrm_list_contacts`, `fluentcrm_create_contact`, `fluentcrm_find_contact_by_email`, `fluentcrm_update_contact` |
| **Tags** | `fluentcrm_attach_tag_to_contact`, `fluentcrm_detach_tag_from_contact` |
| **Lists** | `fluentcrm_attach_contact_to_list`, `fluentcrm_detach_contact_from_list` |
| **Reports** | `fluentcrm_dashboard_stats`, `fluentcrm_custom_fields` |

**Typical Tasks**:

- Lead capture and qualification
- Pipeline stage management
- Contact segmentation
- Sales automation setup
- Quote and proposal generation

<!-- AI-CONTEXT-END -->

## CRM Integration

### FluentCRM Setup

FluentCRM provides a self-hosted WordPress CRM with full API access via MCP.

**Prerequisites**:

1. FluentCRM plugin installed on WordPress
2. Application password created for API access
3. FluentCRM MCP server configured

**Environment Setup**:

> **Security Note**: Never commit actual credentials to version control. Store environment variables in `~/.config/aidevops/mcp-env.sh` (600 permissions). Rotate application passwords regularly.

```bash
# Add to ~/.config/aidevops/mcp-env.sh
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

See `.agent/services/crm/fluentcrm.md` for detailed setup instructions.

## Lead Management

### Lead Capture

When a new lead comes in:

```text
1. Use fluentcrm_create_contact with lead details
2. Apply source tag: fluentcrm_attach_tag_to_contact with tagIds (numeric IDs)
   - First use fluentcrm_list_tags to get tag IDs for tags like 'lead-source-website'
3. Add to nurture list: fluentcrm_attach_contact_to_list with listIds (numeric IDs)
4. Automation triggers welcome sequence
```

**Note**: FluentCRM MCP uses numeric IDs for tags and lists, not slugs. Use `fluentcrm_list_tags` or `fluentcrm_list_lists` to get IDs.

### Lead Qualification

Use tags to track qualification status:

| Tag | Meaning |
|-----|---------|
| `lead-new` | Unqualified lead |
| `lead-mql` | Marketing Qualified Lead |
| `lead-sql` | Sales Qualified Lead |
| `lead-opportunity` | Active opportunity |
| `lead-customer` | Converted customer |
| `lead-lost` | Lost opportunity |

### Lead Scoring

Track engagement with behavior tags:

| Tag | Trigger |
|-----|---------|
| `engaged-email-open` | Opened marketing email |
| `engaged-email-click` | Clicked email link |
| `engaged-website-visit` | Visited key pages |
| `engaged-content-download` | Downloaded content |
| `engaged-demo-request` | Requested demo |

## Pipeline Management

### Pipeline Stages

Map pipeline stages to FluentCRM tags:

| Stage | Tag | Actions |
|-------|-----|---------|
| **Prospect** | `stage-prospect` | Initial outreach |
| **Discovery** | `stage-discovery` | Needs assessment |
| **Proposal** | `stage-proposal` | Quote sent |
| **Negotiation** | `stage-negotiation` | Terms discussion |
| **Closed Won** | `stage-closed-won` | Deal completed |
| **Closed Lost** | `stage-closed-lost` | Deal lost |

### Moving Through Pipeline

```text
# Move contact to next stage
1. fluentcrm_detach_tag_from_contact with current stage tag
2. fluentcrm_attach_tag_to_contact with new stage tag
3. Update custom fields with stage date
```

### Pipeline Reporting

```text
# Get pipeline overview
1. fluentcrm_list_contacts with search for each stage tag
2. Calculate totals and conversion rates
3. Use fluentcrm_dashboard_stats for overall metrics
```

## Sales Automation

### Automated Follow-ups

Create automations in FluentCRM for:

| Trigger | Action |
|---------|--------|
| New lead created | Send welcome email |
| No response 3 days | Send follow-up |
| Email opened | Notify sales rep |
| Link clicked | Update engagement score |
| Demo requested | Create task for sales |

### Sequence Management

```text
# Create nurture sequence
1. fluentcrm_create_automation with trigger 'tag_added'
2. Configure email sequence in FluentCRM admin
3. Set delays between emails
4. Add exit conditions (replied, converted, unsubscribed)
```

## Contact Segmentation

### Segment by Interest

```text
# Tag contacts by product interest
fluentcrm_attach_tag_to_contact with:
- interest-product-a
- interest-product-b
- interest-enterprise
```

### Segment by Company Size

```text
# Tag by company size
- company-size-smb
- company-size-mid-market
- company-size-enterprise
```

### Segment by Industry

```text
# Tag by industry
- industry-saas
- industry-ecommerce
- industry-agency
- industry-healthcare
```

## Proposal Creation

### Proposal Workflow

1. **Gather requirements** from discovery calls
2. **Create proposal** using content templates
3. **Generate quote** with pricing
4. **Send proposal** via email or link
5. **Track engagement** with smart links
6. **Follow up** based on activity

### Smart Link Tracking

```text
# Create trackable proposal link
fluentcrm_create_smart_link with:
- title: "Proposal - {Company Name}"
- target_url: proposal URL
- apply_tags: [tag_id] (numeric ID for 'proposal-viewed' tag)
```

## Quote Generation

### Quote to Invoice Flow

1. **Create quote** in proposal
2. **Get approval** from prospect
3. **Convert to invoice** via QuickFile integration
4. **Track payment** status

See `services/accounting/quickfile.md` for invoice generation.

## Sales Reporting

### Key Metrics

| Metric | How to Calculate |
|--------|------------------|
| **Lead Volume** | Count contacts with `lead-new` tag by date |
| **Conversion Rate** | `stage-closed-won` / total opportunities |
| **Pipeline Value** | Sum of opportunity values by stage |
| **Sales Velocity** | Average time from lead to close |
| **Win Rate** | Won deals / (Won + Lost deals) |

### Dashboard Stats

```text
# Get CRM dashboard stats
fluentcrm_dashboard_stats

Returns:
- Total contacts
- New contacts this period
- Email engagement metrics
- Campaign performance
```

## Integration with Marketing

### Lead Handoff

When marketing qualifies a lead:

```text
1. Marketing applies 'lead-mql' tag
2. Automation notifies sales team
3. Sales reviews and accepts/rejects
4. If accepted, apply 'lead-sql' tag
5. Begin sales sequence
```

### Feedback Loop

```text
# Sales provides feedback to marketing
1. Tag leads with quality indicators
   - lead-quality-high
   - lead-quality-medium
   - lead-quality-low
2. Tag with rejection reasons
   - rejected-budget
   - rejected-timing
   - rejected-fit
```

## Best Practices

### Contact Management

- Keep contact data current
- Use consistent naming for tags
- Document custom field usage
- Regular data cleanup

### Pipeline Hygiene

- Update stages promptly
- Add notes to contact records
- Set follow-up reminders
- Review stale opportunities weekly

### Automation

- Test automations before activating
- Monitor automation performance
- Don't over-automate personal touches
- Review and update sequences quarterly

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Contact not found | Check email spelling, use `fluentcrm_find_contact_by_email` |
| Tag not applying | Verify tag ID exists with `fluentcrm_list_tags` |
| Automation not triggering | Check trigger conditions in FluentCRM admin |
| API errors | Verify credentials and API URL |

### Getting Help

- FluentCRM Docs: https://fluentcrm.com/docs/
- FluentCRM REST API: https://rest-api.fluentcrm.com/
- See `.agent/services/crm/fluentcrm.md` for detailed troubleshooting
