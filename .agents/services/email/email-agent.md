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

```bash
email-agent-helper.sh send --mission M001 --to api@vendor.com \
  --template templates/api-request.md --vars 'service=Acme,project=MyApp'
email-agent-helper.sh poll --mission M001
email-agent-helper.sh extract-codes --mission M001
email-agent-helper.sh thread --mission M001 --conversation conv-xxx
email-agent-helper.sh status --mission M001
```

<!-- AI-CONTEXT-END -->

## Architecture

**Flow**: Mission Orchestrator → SEND (template + SES) → RECEIVE (SES Receipt Rule → S3 → parse → match conversation) → EXTRACT (regex patterns → confidence scores) → THREAD (full audit trail by mission ID)

**Data model**: `conversations` (1 per vendor/topic per mission) → `messages` (outbound/inbound, ordered by timestamp) → `extracted_codes` (otp, token, link, api_key, password)

**SES setup** (see `services/email/ses.md` for full config):

1. Verify receiving domain in SES
2. Create S3 bucket; set MX record to `10 inbound-smtp.{region}.amazonaws.com`
3. Create Receipt Rule: recipient `missions@yourdomain.com` → S3 action (`incoming/` prefix)
4. Update config: `s3_receive_bucket` and `s3_receive_prefix` in `email-agent-config.json`

## Template System

Markdown files with `{{variable}}` placeholders. First `Subject:` line → email subject; body follows first blank line. Store in `{mission-dir}/templates/`.

| Pattern | Use Case | Key Variables |
|---------|----------|---------------|
| API access request | Request API credentials from a vendor | service_name, project_name, expected_volume |
| Account signup confirmation | Confirm a signup or verify email | service_name, confirmation_action |
| Support inquiry | Ask vendor support a question | service_name, issue_description |
| Cancellation request | Cancel a service or subscription | service_name, account_id, reason |

## Verification Code Extraction

Auto-extracted from inbound emails. Confidence threshold: 0.7 (configurable).

| Type | Pattern | Confidence |
|------|---------|------------|
| **OTP** | 4-8 digit numeric (`Code: 123456`) | 0.95 |
| **Token** | 20+ char alphanumeric | 0.95 |
| **Confirmation link** | URLs with verify/confirm/activate params | 0.85 |
| **API key** | Labelled credentials (`API Key: sk_live_xxx`) | 0.95 |
| **Password** | Temporary passwords | 0.70 |

**AI fallback** (non-standard formats):

```bash
ai-research --prompt "Extract any verification codes, API keys, or confirmation links from this email body: {body_text}" --model haiku
```

## Integration with Mission System

Invoked by mission orchestrator when a milestone requires 3rd-party communication. See `workflows/mission-orchestrator.md`.

```bash
# Send → poll → extract → use
msg_id=$(email-agent-helper.sh send --mission M001 --to api@stripe.com \
  --template templates/api-request.md --vars 'service_name=Stripe')
email-agent-helper.sh poll --mission M001
email-agent-helper.sh extract-codes --mission M001
email-agent-helper.sh status --mission M001
# Orchestrator reads extracted_codes and passes to the next feature
```

**Credential flow**: Extracted codes → mission state file (`Resources` section) → next feature reads by secret name. Move API keys/passwords to gopass/Vaultwarden immediately after extraction. Never reference by value.

## Security

- **Mission-scoped**: Every operation requires `--mission` — no orphan communications
- **Credential masking**: Extracted codes displayed with partial masking (`sk_l...xyz`)
- **No credential logging**: Full code values never appear in logs or git
- **SES sender verification**: Can only send from verified SES identities
- **S3 access control**: Receive bucket should have minimal IAM permissions
- **Audit trail**: All messages and extractions stored in SQLite with timestamps
- **Template review**: Templates are plain text files — reviewable before use

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

**Emails not sending**: `ses-helper.sh verified-emails` → `ses-helper.sh quota` → `aws sts get-caller-identity` → check SES sandbox mode (may need to verify recipient addresses)

**Emails not received**: `dig MX missions.yourdomain.com` → `aws ses describe-active-receipt-rule-set` → `aws s3 ls s3://bucket/incoming/` → check S3 bucket policy allows SES to write

**Codes not extracted**: `email-agent-helper.sh thread --conversation <id>` → `email-agent-helper.sh extract-codes --message <id>` → use AI fallback for non-standard formats

## Related

- `services/email/ses.md` — SES configuration and management
- `services/email/email-delivery-test.md` — Email deliverability testing
- `services/payments/procurement.md` — Procurement agent (similar mission integration pattern)
- `workflows/mission-orchestrator.md` — Mission orchestrator (invokes email agent)
- `scripts/email-to-markdown.py` — Email parsing pipeline
- `scripts/email-thread-reconstruction.py` — Thread building
- `scripts/email-signature-parser-helper.sh` — Contact extraction from signatures
