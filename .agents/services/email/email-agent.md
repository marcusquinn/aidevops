---
description: Autonomous email agent for mission 3rd-party communication - send templated emails, receive/parse responses, extract verification codes, thread conversations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Email Agent - Autonomous Mission Communication

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Enable missions to communicate with 3rd parties autonomously (signup, API access, vendor communication)
- **Helper**: `scripts/email-agent-helper.sh [command] [options]`
- **Config**: `configs/email-agent-config.json` (from `.json.txt` template)
- **Credentials**: AWS SES via `aidevops secret` (gopass) or `credentials.sh`
- **Database**: `~/.aidevops/.agent-workspace/email-agent/conversations.db` (SQLite)

**Key principle**: Every email is linked to a mission ID. No autonomous email without a mission context.

**Quick commands:**

```bash
# Send templated email
email-agent-helper.sh send --mission M001 --to api@vendor.com \
  --template templates/api-request.md --vars 'service=Acme,project=MyApp'

# Poll for responses
email-agent-helper.sh poll --mission M001

# Extract verification codes
email-agent-helper.sh extract-codes --mission M001

# View conversation
email-agent-helper.sh thread --mission M001 --conversation conv-xxx

# Check status
email-agent-helper.sh status --mission M001
```

<!-- AI-CONTEXT-END -->

## Architecture

### Email Flow

```text
Mission Orchestrator
    │
    ▼
1. SEND (outbound)
    ├── Load template + variable substitution
    ├── AWS SES send-email / send-raw-email (for threading)
    ├── Store in conversations.db (outbound message)
    └── Conversation status → "waiting"
    │
    ▼
2. RECEIVE (inbound via SES Receipt Rules)
    ├── SES Receipt Rule → S3 bucket (configured per domain)
    ├── email-agent-helper.sh poll → downloads from S3
    ├── Parse with email-to-markdown.py (or fallback header grep)
    ├── Match to conversation (In-Reply-To or subject+email)
    ├── Store in conversations.db (inbound message)
    └── Auto-extract verification codes
    │
    ▼
3. EXTRACT (verification codes)
    ├── Regex patterns: OTP (6-digit), tokens, confirmation links
    ├── Store in extracted_codes table with confidence scores
    └── Mission reads codes for credential management
    │
    ▼
4. THREAD (conversation history)
    ├── Messages linked by conversation ID
    ├── Conversations linked by mission ID
    └── Full audit trail: who said what, when, extracted codes
```

### Data Model

```text
conversations (1 per vendor/topic per mission)
├── messages (ordered by timestamp)
│   ├── outbound (sent by mission)
│   └── inbound (received from vendor)
└── extracted_codes (from inbound messages)
    ├── otp (numeric codes)
    ├── token (alphanumeric)
    ├── link (confirmation URLs)
    ├── api_key (API credentials)
    └── password (temporary passwords)
```

### SES Receipt Rules Setup

To receive emails, configure SES Receipt Rules to deliver to S3:

1. **Verify receiving domain** in SES (the domain you want to receive email on)
2. **Create S3 bucket** for incoming emails (or use existing)
3. **Create SES Receipt Rule Set**:
   - Recipient: `missions@yourdomain.com` (or `*@missions.yourdomain.com`)
   - Action: S3 (bucket name, prefix `incoming/`)
4. **Configure MX record**: Point the receiving domain's MX to SES inbound endpoint
   - `10 inbound-smtp.{region}.amazonaws.com`
5. **Update config**: Set `s3_receive_bucket` and `s3_receive_prefix` in `email-agent-config.json`

```bash
# Verify domain for receiving
aws ses verify-domain-identity --domain missions.yourdomain.com

# Create receipt rule (after MX record is configured)
aws ses create-receipt-rule-set --rule-set-name mission-emails
aws ses create-receipt-rule --rule-set-name mission-emails --rule '{
  "Name": "store-to-s3",
  "Enabled": true,
  "Recipients": ["missions@yourdomain.com"],
  "Actions": [{
    "S3Action": {
      "BucketName": "my-mission-emails",
      "ObjectKeyPrefix": "incoming/"
    }
  }]
}'
aws ses set-active-receipt-rule-set --rule-set-name mission-emails
```

## Template System

Templates are markdown files with `{{variable}}` placeholders. The first `Subject:` line becomes the email subject; everything after the first blank line becomes the body.

### Template Format

```markdown
Subject: API Access Request for {{service_name}}

Dear {{contact_name}},

I am writing to request API access to {{service_name}} for our project {{project_name}}.

We are building {{project_description}} and would like to integrate with your
{{api_type}} API. Our expected usage is approximately {{expected_volume}} requests
per month.

Could you please provide:
1. API credentials or an invitation to your developer portal
2. Documentation for the {{api_type}} API
3. Any rate limits or usage policies we should be aware of

Thank you for your time.

Best regards,
{{sender_name}}
{{sender_title}}
{{sender_company}}
```

### Usage

```bash
email-agent-helper.sh send --mission M001 --to api@vendor.com \
  --template path/to/api-request.md \
  --vars 'service_name=Acme API,contact_name=API Team,project_name=MyProject,project_description=a CRM platform,api_type=REST,expected_volume=10000,sender_name=Alex,sender_title=CTO,sender_company=MyCompany'
```

### Built-in Template Patterns

Common mission communication patterns:

| Pattern | Use Case | Key Variables |
|---------|----------|---------------|
| API access request | Request API credentials from a vendor | service_name, project_name, expected_volume |
| Account signup confirmation | Confirm a signup or verify email | service_name, confirmation_action |
| Support inquiry | Ask vendor support a question | service_name, issue_description |
| Cancellation request | Cancel a service or subscription | service_name, account_id, reason |

Create templates in the mission directory: `{mission-dir}/templates/`.

## Verification Code Extraction

The agent automatically extracts verification codes from inbound emails using pattern matching.

### Supported Patterns

| Type | Pattern | Examples |
|------|---------|----------|
| **OTP** | 4-8 digit numeric codes | `Code: 123456`, `Verification: 8472` |
| **Token** | 20+ char alphanumeric | `Token: abc123def456...` |
| **Confirmation link** | URLs with verify/confirm/activate params | `https://app.com/verify?token=xxx` |
| **API key** | Labelled API credentials | `API Key: sk_live_xxx` |
| **Password** | Temporary passwords | `Password: TempPass123!` |

### Confidence Scores

| Score | Meaning |
|-------|---------|
| 0.95 | High confidence — clear label + expected format |
| 0.85 | Medium confidence — URL pattern match |
| 0.70 | Lower confidence — partial pattern match |

### AI Fallback

For non-standard verification formats, use the `ai-research` MCP tool to analyse the email body:

```bash
# If regex extraction finds nothing, the orchestrator can use AI
ai-research --prompt "Extract any verification codes, API keys, or confirmation links from this email body: {body_text}" --model haiku
```

## Integration with Mission System

### Mission Orchestrator Usage

The mission orchestrator invokes the email agent when a milestone requires 3rd-party communication:

```text
Mission: "Build a SaaS with Stripe payments"
├── Milestone 1: Infrastructure
│   ├── Feature: Register domain (email agent: domain registrar)
│   └── Feature: Setup hosting (email agent: hosting provider)
├── Milestone 2: Payments
│   └── Feature: Stripe API access (email agent: Stripe support)
```

### Orchestrator Integration Pattern

```bash
# 1. Send initial request
msg_id=$(email-agent-helper.sh send --mission M001 --to api@stripe.com \
  --template templates/api-request.md --vars 'service_name=Stripe')

# 2. Wait and poll (in pulse loop)
email-agent-helper.sh poll --mission M001

# 3. Check for codes
email-agent-helper.sh extract-codes --mission M001

# 4. Read conversation status
email-agent-helper.sh status --mission M001

# 5. If response received with code, use it
# The orchestrator reads extracted_codes and passes to the next feature
```

### Credential Flow

```text
Email Agent extracts code
    ↓
Mission state file updated:
  Resources:
  - [x] Stripe API key (extracted from email, conv: conv-xxx)
    ↓
Next feature uses the credential:
  /full-loop "Configure Stripe with API key from mission resources"
```

**Security**: Extracted credentials are stored in the SQLite database with masked display. For sensitive credentials (API keys, passwords), the mission orchestrator should move them to gopass/Vaultwarden immediately after extraction and reference them by secret name, not value.

## Security

- **Mission-scoped**: Every email operation requires a `--mission` flag — no orphan communications
- **Credential masking**: Extracted codes displayed with partial masking (`sk_l...xyz`)
- **No credential logging**: Full code values never appear in logs or git
- **SES sender verification**: Can only send from verified SES identities
- **S3 access control**: Receive bucket should have minimal IAM permissions
- **Audit trail**: All messages and extractions stored in SQLite with timestamps
- **Template review**: Templates are plain text files — reviewable before use

## Configuration

### Config Template

See `configs/email-agent-config.json.txt`. Copy to `configs/email-agent-config.json` and customise.

Key settings:

```json
{
  "default_from_email": "missions@yourdomain.com",
  "aws_region": "eu-west-2",
  "s3_receive_bucket": "my-mission-emails",
  "s3_receive_prefix": "incoming/",
  "poll_interval_seconds": 300,
  "max_conversations_per_mission": 20,
  "code_extraction_confidence_threshold": 0.7
}
```

## Troubleshooting

### Emails Not Sending

1. Check SES sender verification: `ses-helper.sh verified-emails`
2. Check SES sending quota: `ses-helper.sh quota`
3. Verify AWS credentials: `aws sts get-caller-identity`
4. Check SES sandbox mode — may need to verify recipient addresses too

### Emails Not Received

1. Verify MX record points to SES: `dig MX missions.yourdomain.com`
2. Check SES Receipt Rule is active: `aws ses describe-active-receipt-rule-set`
3. Check S3 bucket for objects: `aws s3 ls s3://bucket/incoming/`
4. Check S3 bucket policy allows SES to write

### Verification Codes Not Extracted

1. Check message body was parsed: `email-agent-helper.sh thread --conversation <id>`
2. Re-run extraction: `email-agent-helper.sh extract-codes --message <id>`
3. For non-standard formats, use AI fallback (see "AI Fallback" above)

## Related

- `services/email/ses.md` — SES configuration and management
- `services/email/email-delivery-test.md` — Email deliverability testing
- `services/payments/procurement.md` — Procurement agent (similar mission integration pattern)
- `workflows/mission-orchestrator.md` — Mission orchestrator (invokes email agent)
- `scripts/email-to-markdown.py` — Email parsing pipeline
- `scripts/email-thread-reconstruction.py` — Thread building
- `scripts/email-signature-parser-helper.sh` — Contact extraction from signatures
