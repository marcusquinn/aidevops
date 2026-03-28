---
description: Mission email agent - 3rd-party communication for autonomous missions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Mission Email Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Send/receive emails on behalf of missions communicating with 3rd parties (vendors, APIs, services)
- **Script**: `scripts/mission-email-helper.sh`
- **Templates**: `templates/email/*.txt`
- **Database**: `~/.aidevops/.agent-workspace/mail/mission-email.db` (SQLite)
- **Depends on**: `ses-helper.sh` (SES credentials), `credential-helper.sh` (mission credentials)
- **Commands**: `send`, `receive`, `parse`, `extract-code`, `thread`, `templates`

<!-- AI-CONTEXT-END -->

## When to Use

- Signing up for services, requesting API access, communicating with vendors
- Receiving verification codes (email verification, 2FA setup)
- Account activation (waiting for approval, responding to verification requests)

## Architecture

```text
Mission Orchestrator
    |
    v
mission-email-helper.sh
    |
    +-- send ---------> SES (aws ses send-raw-email) --> Recipient inbox
    |
    +-- receive <------- S3 bucket (SES receipt rule)
    |       |
    |       +-- parse (Python email module)
    |       +-- extract-code (regex patterns)
    |       +-- thread matching (In-Reply-To / counterparty)
    |
    +-- thread -------> SQLite (conversation state)
    |
    +-- templates ----> templates/email/*.txt
```

**Receive setup:** SES receipt rule → S3; S3 accessible with same AWS credentials; domain MX records pointing to SES.

**Thread matching priority:** (1) `In-Reply-To` header matching a previous SES Message-ID, (2) sender email matching thread's counterparty, (3) new thread created if no match.

**Thread fields:** `thread_id` (e.g., `thr-20260228-143022-a1b2c3d4`), `mission_id`, `counterparty`, `status` (`active` | `waiting` | `resolved` | `abandoned`).

**Verification code extraction** (auto on `receive`, or via `extract-code`):

| Pattern | Example | Type |
|---------|---------|------|
| Numeric codes | `Your code is 847291` | `numeric_code` |
| Alphanumeric tokens | `API key: sk_live_abc123def456` | `token` |
| Verification URLs | `https://example.com/verify?token=abc` | `verification_url` |
| Temporary passwords | `Temporary password: Xk9#mP2q` | `temporary_password` |

## Usage

### Send

```bash
mission-email-helper.sh send \
  --account production \
  --from noreply@yourdomain.com \
  --to api-support@vendor.com \
  --subject "API Access Request" \
  --template api-access-request \
  --var COMPANY_NAME="My Company" \
  --var USE_CASE="Automated integration" \
  --var SENDER_NAME="John Smith"

mission-email-helper.sh send \
  --account production \
  --from noreply@yourdomain.com \
  --to support@vendor.com \
  --subject "Account Status" \
  --body "Please provide an update on our account application." \
  --thread-id thr-20260228-143022-a1b2c3d4
```

### Receive

```bash
mission-email-helper.sh receive --account production --mailbox my-ses-bucket/inbound

mission-email-helper.sh receive \
  --account production \
  --mailbox my-ses-bucket/inbound \
  --since 2026-02-28T00:00:00Z \
  --thread-id thr-20260228-143022-a1b2c3d4
```

### Parse and Extract

```bash
mission-email-helper.sh parse /path/to/email.eml
cat email.eml | mission-email-helper.sh parse -
echo "Your verification code is 847291" | mission-email-helper.sh extract-code -
mission-email-helper.sh extract-code /path/to/email-body.txt
```

### Thread Management

```bash
mission-email-helper.sh thread --create \
  --mission m001 \
  --subject "Stripe API Access" \
  --counterparty api-support@stripe.com \
  --context "Need API keys for payment processing integration"

mission-email-helper.sh thread --list --mission m001
mission-email-helper.sh thread --show thr-20260228-143022-a1b2c3d4
```

### Templates

```bash
mission-email-helper.sh templates --list
mission-email-helper.sh templates --show api-access-request
```

## Templates

Location: `~/.aidevops/agents/templates/email/*.txt`. Placeholders: `{{KEY}}`, replaced by `--var KEY=value`.

| Template | Purpose |
|----------|---------|
| `api-access-request` | Request developer/API access from vendors |
| `account-signup-followup` | Follow up on pending account approvals |
| `verification-response` | Respond to identity/business verification requests |
| `support-inquiry` | Technical support or billing questions |
| `generic` | Minimal template for custom messages |

Custom template format — first `#` line is the description:

```text
# Template Description - shown in template list
Hello {{RECIPIENT_NAME}},

{{BODY}}

Best regards,
{{SENDER_NAME}}
```

## Mission Integration

Record threads in the mission state file:

```markdown
### External Dependencies

| Dependency | Type | Status | Notes |
|------------|------|--------|-------|
| Stripe API access | api | pending | Thread: thr-20260228-143022-a1b2c3d4 |
```

**Orchestrator workflow:** Create thread → send email (template) → poll `receive` → extract codes (auto-stored in DB) → hand off to `credential-helper.sh` → mark thread `resolved`.

**Credential handoff:**

```bash
code=$(sqlite3 ~/.aidevops/.agent-workspace/mail/mission-email.db \
  "SELECT ec.code_value FROM extracted_codes ec
   JOIN messages m ON ec.message_id = m.id
   WHERE m.thread_id = 'thr-xxx' AND ec.used = 0
   ORDER BY ec.extracted_at DESC LIMIT 1;")

aidevops secret set VENDOR_API_KEY  # user enters the value

sqlite3 ~/.aidevops/.agent-workspace/mail/mission-email.db \
  "UPDATE extracted_codes SET used = 1 WHERE code_value = '$code';"
```

## Security

- Credentials managed via `ses-config.json` (same as `ses-helper.sh`)
- Extracted codes stored in local SQLite only — database permissions must be 600
- Never log full API keys or passwords in verbose mode
- Thread context is sensitive — treat the database as confidential

## Related

- `services/email/ses.md` -- SES provider guide
- `scripts/ses-helper.sh` -- SES management commands
- `scripts/credential-helper.sh` -- Multi-tenant credential storage
- `workflows/mission-orchestrator.md` -- Mission execution lifecycle
- `templates/mission-template.md` -- Mission state file format
