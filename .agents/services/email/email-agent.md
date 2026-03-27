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

See `services/email/ses.md` for full SES configuration. Summary:

1. Verify receiving domain in SES
2. Create S3 bucket for incoming emails; set MX record to `10 inbound-smtp.{region}.amazonaws.com`
3. Create SES Receipt Rule: recipient `missions@yourdomain.com` → S3 action (`incoming/` prefix)
4. Update config: `s3_receive_bucket` and `s3_receive_prefix` in `email-agent-config.json`

## Template System

Templates are markdown files with `{{variable}}` placeholders. First `Subject:` line → email subject; everything after the first blank line → body. Store in `{mission-dir}/templates/`.

### Built-in Template Patterns

| Pattern | Use Case | Key Variables |
|---------|----------|---------------|
| API access request | Request API credentials from a vendor | service_name, project_name, expected_volume |
| Account signup confirmation | Confirm a signup or verify email | service_name, confirmation_action |
| Support inquiry | Ask vendor support a question | service_name, issue_description |
| Cancellation request | Cancel a service or subscription | service_name, account_id, reason |

## Verification Code Extraction

Auto-extracted from inbound emails via pattern matching.

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

The mission orchestrator invokes the email agent when a milestone requires 3rd-party communication (e.g., domain registrar, hosting provider, API vendor). See `workflows/mission-orchestrator.md` for the full orchestration pattern.

### Orchestrator Integration Pattern

```bash
# Send → poll → extract → use
msg_id=$(email-agent-helper.sh send --mission M001 --to api@stripe.com \
  --template templates/api-request.md --vars 'service_name=Stripe')
email-agent-helper.sh poll --mission M001
email-agent-helper.sh extract-codes --mission M001
email-agent-helper.sh status --mission M001
# Orchestrator reads extracted_codes and passes to the next feature
```

### Credential Flow

Extracted codes → mission state file (`Resources` section) → next feature reads by secret name.

**Security**: Move sensitive credentials (API keys, passwords) to gopass/Vaultwarden immediately after extraction. Never reference by value — use secret name only.

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
