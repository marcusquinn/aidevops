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

- **Helper**: `scripts/email-agent-helper.sh [command] [options]`
- **Config**: `configs/email-agent-config.json` (from `.json.txt` template)
- **Credentials**: AWS SES via `aidevops secret` (gopass) or `credentials.sh`
- **Database**: `~/.aidevops/.agent-workspace/email-agent/conversations.db` (SQLite)

**Key principle**: Every email operation requires `--mission <ID>`. No autonomous email without a mission context.

<!-- AI-CONTEXT-END -->

## Architecture

```text
Mission Orchestrator
    │
    ▼
1. SEND — Load template + variable substitution → SES send → conversations.db → status "waiting"
2. RECEIVE — SES Receipt Rule → S3 → poll → parse (email-to-markdown.py) → match conversation → store → auto-extract codes
3. EXTRACT — Regex: OTP (4-8 digit), tokens (20+ char), confirmation links, API keys, passwords → extracted_codes table with confidence scores
4. THREAD — Messages linked by conversation ID → conversations linked by mission ID → full audit trail
```

### Data Model

```text
conversations (1 per vendor/topic per mission)
├── messages (ordered by timestamp, outbound + inbound)
└── extracted_codes (otp | token | link | api_key | password)
```

### SES Receipt Rules Setup

To receive emails, configure SES Receipt Rules to deliver to S3:

1. Verify receiving domain in SES
2. Create/use S3 bucket for incoming emails
3. Create SES Receipt Rule Set — recipient: `missions@yourdomain.com`, action: S3 (bucket, prefix `incoming/`)
4. Point MX record to SES: `10 inbound-smtp.{region}.amazonaws.com`
5. Set `s3_receive_bucket` and `s3_receive_prefix` in config

```bash
aws ses verify-domain-identity --domain missions.yourdomain.com
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

## Commands

```bash
# Send templated email
email-agent-helper.sh send --mission M001 --to api@vendor.com \
  --template templates/api-request.md --vars 'service=Acme,project=MyApp'

# Poll for responses
email-agent-helper.sh poll --mission M001

# Extract verification codes
email-agent-helper.sh extract-codes --mission M001

# View conversation thread
email-agent-helper.sh thread --mission M001 --conversation conv-xxx

# Check mission email status
email-agent-helper.sh status --mission M001
```

## Template System

Templates are markdown files with `{{variable}}` placeholders. First `Subject:` line becomes the email subject; everything after the first blank line becomes the body. Store templates in `{mission-dir}/templates/`.

Common patterns: API access request, account signup confirmation, support inquiry, cancellation request.

## Verification Code Extraction

Automatically extracts codes from inbound emails via pattern matching:

| Type | Pattern | Examples |
|------|---------|----------|
| **OTP** | 4-8 digit numeric | `Code: 123456`, `Verification: 8472` |
| **Token** | 20+ char alphanumeric | `Token: abc123def456...` |
| **Confirmation link** | URLs with verify/confirm/activate | `https://app.com/verify?token=xxx` |
| **API key** | Labelled API credentials | `API Key: sk_live_xxx` |
| **Password** | Temporary passwords | `Password: TempPass123!` |

Confidence: 0.95 (clear label + format), 0.85 (URL pattern), 0.70 (partial match).

**AI fallback** for non-standard formats: `ai-research --prompt "Extract verification codes, API keys, or confirmation links from: {body_text}" --model haiku`

## Mission Integration

The orchestrator invokes the email agent when a milestone requires 3rd-party communication. Workflow: send → poll → extract-codes → status → use extracted credential in next feature.

**Credential flow**: Extracted credentials stored in SQLite with masked display. For sensitive credentials (API keys, passwords), move to gopass/Vaultwarden immediately after extraction and reference by secret name, not value.

## Security

- **Mission-scoped**: Every operation requires `--mission` — no orphan communications
- **Credential masking**: Extracted codes displayed with partial masking (`sk_l...xyz`)
- **No credential logging**: Full values never appear in logs or git
- **SES sender verification**: Can only send from verified SES identities
- **S3 access control**: Receive bucket with minimal IAM permissions
- **Audit trail**: All messages and extractions in SQLite with timestamps
- **Template review**: Templates are plain text — reviewable before use

## Configuration

See `configs/email-agent-config.json.txt`. Copy to `configs/email-agent-config.json` and customise.

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

**Not sending**: Check SES sender verification (`ses-helper.sh verified-emails`), sending quota (`ses-helper.sh quota`), AWS credentials (`aws sts get-caller-identity`), sandbox mode (may need recipient verification).

**Not receiving**: Verify MX record (`dig MX missions.yourdomain.com`), receipt rule active (`aws ses describe-active-receipt-rule-set`), S3 objects (`aws s3 ls s3://bucket/incoming/`), S3 bucket policy allows SES writes.

**Codes not extracted**: Check message body parsed (`email-agent-helper.sh thread --conversation <id>`), re-run extraction (`email-agent-helper.sh extract-codes --message <id>`), use AI fallback for non-standard formats.

## Related

- `services/email/ses.md` — SES configuration and management
- `services/email/email-delivery-test.md` — Email deliverability testing
- `services/payments/procurement.md` — Procurement agent (similar mission integration)
- `workflows/mission-orchestrator.md` — Mission orchestrator (invokes email agent)
- `scripts/email-to-markdown.py` — Email parsing pipeline
- `scripts/email-thread-reconstruction.py` — Thread building
- `scripts/email-signature-parser-helper.sh` — Contact extraction from signatures
