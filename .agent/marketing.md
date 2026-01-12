---
name: marketing
description: Marketing strategy and campaigns - digital marketing, analytics, brand management
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

# Marketing - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Marketing strategy, campaign execution, and analytics
- **CRM Integration**: FluentCRM MCP for email marketing and automation

**Related Agents**:

- `content.md` - Content creation and copywriting
- `seo.md` - Search optimization
- `sales.md` - Sales alignment and lead handoff
- `services/crm/fluentcrm.md` - CRM operations (detailed)

**FluentCRM MCP Tools**:

| Category | Key Tools |
|----------|-----------|
| **Campaigns** | `fluentcrm_list_campaigns`, `fluentcrm_create_campaign`, `fluentcrm_pause_campaign`, `fluentcrm_resume_campaign` |
| **Templates** | `fluentcrm_list_email_templates`, `fluentcrm_create_email_template` |
| **Automations** | `fluentcrm_list_automations`, `fluentcrm_create_automation` |
| **Lists** | `fluentcrm_list_lists`, `fluentcrm_create_list`, `fluentcrm_attach_contact_to_list` |
| **Tags** | `fluentcrm_list_tags`, `fluentcrm_create_tag`, `fluentcrm_attach_tag_to_contact` |
| **Smart Links** | `fluentcrm_create_smart_link`, `fluentcrm_generate_smart_link_shortcode` |
| **Reports** | `fluentcrm_dashboard_stats` |

**Typical Tasks**:

- Email campaign creation and management
- Marketing automation setup
- Audience segmentation
- Lead nurturing sequences
- Campaign performance analysis

<!-- AI-CONTEXT-END -->

## Email Marketing

### FluentCRM Setup

FluentCRM provides self-hosted email marketing with full API access via MCP.

**Prerequisites**:

1. FluentCRM plugin installed on WordPress
2. Application password created for API access
3. FluentCRM MCP server configured
4. Email sending configured (SMTP or SES)

**Environment Setup**:

```bash
# Add to ~/.config/aidevops/mcp-env.sh
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

See `services/crm/fluentcrm.md` for detailed setup instructions.

## Campaign Management

### Campaign Types

| Type | Use Case | FluentCRM Feature |
|------|----------|-------------------|
| **Newsletter** | Regular updates | Email Campaign |
| **Promotional** | Sales and offers | Email Campaign |
| **Nurture** | Lead education | Automation Funnel |
| **Transactional** | Order confirmations | Automation Funnel |
| **Re-engagement** | Win back inactive | Automation Funnel |

### Creating a Campaign

```text
1. Create email template
   fluentcrm_create_email_template with:
   - title: "Campaign Name - Template"
   - subject: "Your Subject Line"
   - body: HTML content

2. Create campaign
   fluentcrm_create_campaign with:
   - title: "Campaign Name"
   - subject: "Email Subject"
   - template_id: template ID from step 1
   - recipient_list: [list IDs]

3. Review in FluentCRM admin
4. Schedule or send immediately
```

### Campaign Workflow

1. **Plan** - Define goals, audience, messaging
2. **Create** - Build template and campaign
3. **Test** - Send test emails, check rendering
4. **Schedule** - Set send time for optimal engagement
5. **Monitor** - Track opens, clicks, conversions
6. **Optimize** - A/B test and improve

## Email Templates

### Template Best Practices

| Element | Best Practice |
|---------|---------------|
| **Subject** | 40-60 chars, personalized, clear value |
| **Preheader** | Complement subject, 40-100 chars |
| **Header** | Logo, clear branding |
| **Body** | Single column, scannable, mobile-first |
| **CTA** | Clear, contrasting button, above fold |
| **Footer** | Unsubscribe link, contact info, social |

### Template Variables

FluentCRM supports personalization:

```html
{{contact.first_name}} - First name
{{contact.last_name}} - Last name
{{contact.email}} - Email address
{{contact.full_name}} - Full name
{{contact.custom.field_name}} - Custom fields
```

### Creating Templates

```text
fluentcrm_create_email_template with:
- title: "Welcome Email Template"
- subject: "Welcome to {{company_name}}, {{contact.first_name}}!"
- body: "<html>...</html>"
```

## Marketing Automation

### Automation Triggers

| Trigger | Use Case |
|---------|----------|
| `tag_added` | When tag is applied |
| `list_added` | When contact joins list |
| `form_submitted` | When form is completed |
| `link_clicked` | When email link is clicked |
| `email_opened` | When email is opened |

### Common Automation Sequences

#### Welcome Sequence

```text
Trigger: list_added (Newsletter list)
Day 0: Welcome email
Day 2: Value content email
Day 5: Product introduction
Day 7: Social proof / testimonials
Day 10: Soft CTA
```

#### Lead Nurture Sequence

```text
Trigger: tag_added (lead-mql)
Day 0: Educational content
Day 3: Case study
Day 7: Comparison guide
Day 10: Demo invitation
Day 14: Follow-up if no response
```

#### Re-engagement Sequence

```text
Trigger: tag_added (inactive-90-days)
Day 0: "We miss you" email
Day 3: Best content roundup
Day 7: Special offer
Day 14: Last chance + unsubscribe option
```

### Creating Automations

```text
fluentcrm_create_automation with:
- title: "Welcome Sequence"
- description: "New subscriber welcome series"
- trigger: "list_added"

Then configure steps in FluentCRM admin:
1. Add email actions
2. Set delays between emails
3. Add conditions and branches
4. Set exit conditions
```

## Audience Segmentation

### Segmentation Strategies

| Segment Type | Tags/Lists | Use Case |
|--------------|------------|----------|
| **Demographic** | industry-*, company-size-* | Targeted messaging |
| **Behavioral** | engaged-*, downloaded-* | Engagement-based |
| **Lifecycle** | lead-*, customer-* | Stage-appropriate |
| **Interest** | interest-*, product-* | Relevant content |
| **Source** | source-*, campaign-* | Attribution |

### Creating Segments

```text
# Create list for segment
fluentcrm_create_list with:
- title: "Enterprise Prospects"
- slug: "enterprise-prospects"
- description: "Companies with 500+ employees interested in enterprise plan"

# Add contacts matching criteria
fluentcrm_attach_contact_to_list with subscriberId and listIds
```

### Dynamic Segmentation

Use tags for dynamic segments that update automatically:

```text
# Create behavior tags
fluentcrm_create_tag with:
- title: "Engaged - Last 30 Days"
- slug: "engaged-30-days"

# Automation applies/removes based on activity
```

## Smart Links

### Trackable Links

Smart Links track clicks and can trigger actions:

```text
fluentcrm_create_smart_link with:
- title: "Product Demo CTA"
- slug: "demo-cta"
- target_url: "https://your-site.com/demo"
- apply_tags: [tag_id for 'clicked-demo-cta']
```

### Use Cases

| Use Case | Configuration |
|----------|---------------|
| **Content tracking** | Apply interest tags on click |
| **Lead scoring** | Apply engagement tags |
| **Segmentation** | Add to lists on click |
| **Retargeting** | Tag for ad audiences |

### Generating Shortcodes

```text
fluentcrm_generate_smart_link_shortcode with:
- slug: "demo-cta"
- linkText: "Request a Demo"

Returns: <a href="{{fc_smart_link slug='demo-cta'}}">Request a Demo</a>
```

## Content Marketing Integration

### Content to Campaign Workflow

1. **Create content** using `content.md` agent
2. **Optimize for SEO** using `seo.md` agent
3. **Create email** promoting content
4. **Segment audience** by interest
5. **Send campaign** to relevant segments
6. **Track engagement** and conversions

### Content Promotion Campaigns

```text
# For each new blog post:
1. Create email template with post excerpt
2. Create campaign targeting relevant interest tags
3. Add smart link to track clicks
4. Schedule for optimal send time
```

## Lead Generation

### Lead Magnet Workflow

1. **Create lead magnet** (ebook, guide, template)
2. **Create landing page** with form
3. **Create FluentCRM list** for leads
4. **Set up automation** for delivery
5. **Create nurture sequence** for follow-up

### Form Integration

FluentCRM integrates with:

- Fluent Forms
- WPForms
- Gravity Forms
- Contact Form 7
- Custom forms via API

### Lead Handoff to Sales

```text
# When lead is qualified:
1. Apply 'lead-mql' tag
2. Automation notifies sales team
3. Sales reviews and accepts
4. Apply 'lead-sql' tag
5. Remove from marketing sequences
```

## Analytics & Reporting

### Key Metrics

| Metric | Target | How to Improve |
|--------|--------|----------------|
| **Open Rate** | 20-30% | Better subjects, send time |
| **Click Rate** | 2-5% | Better CTAs, content |
| **Conversion Rate** | 1-3% | Landing page optimization |
| **Unsubscribe Rate** | <0.5% | Better targeting, frequency |
| **List Growth** | 5-10%/mo | More lead magnets, promotion |

### Dashboard Stats

```text
fluentcrm_dashboard_stats

Returns:
- Total contacts
- New contacts this period
- Email engagement metrics
- Campaign performance
```

### Campaign Analysis

After each campaign:

1. Review open and click rates
2. Analyze by segment performance
3. Identify top-performing content
4. Note unsubscribes and complaints
5. Document learnings for future

## A/B Testing

### What to Test

| Element | Test Ideas |
|---------|------------|
| **Subject Line** | Length, personalization, emoji |
| **Send Time** | Day of week, time of day |
| **From Name** | Company vs. person |
| **CTA** | Button text, color, placement |
| **Content** | Long vs. short, format |

### Testing Process

1. Create two template variations
2. Split audience randomly
3. Send to small test group (10-20%)
4. Wait for results (24-48 hours)
5. Send winner to remaining audience

## Best Practices

### Email Deliverability

- Warm up new sending domains
- Maintain clean lists (remove bounces)
- Use double opt-in
- Monitor sender reputation
- Authenticate with SPF, DKIM, DMARC

### List Hygiene

- Remove hard bounces immediately
- Re-engage or remove inactive (90+ days)
- Honor unsubscribes instantly
- Validate emails on import

### Compliance

| Regulation | Requirements |
|------------|--------------|
| **GDPR** | Explicit consent, right to erasure |
| **CAN-SPAM** | Unsubscribe link, physical address |
| **CASL** | Express consent, identification |

### Frequency

- Newsletter: Weekly or bi-weekly
- Promotional: 2-4 per month max
- Transactional: As needed
- Nurture: Spaced 2-5 days apart

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Low open rates | Test subjects, check deliverability |
| High unsubscribes | Review frequency, improve targeting |
| Bounces | Clean list, validate emails |
| Spam complaints | Better consent, relevant content |
| Template rendering | Test across email clients |

### Getting Help

- FluentCRM Docs: https://fluentcrm.com/docs/
- FluentCRM REST API: https://rest-api.fluentcrm.com/
- See `services/crm/fluentcrm.md` for detailed troubleshooting
