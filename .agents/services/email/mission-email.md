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

Missions that involve:

- **Signing up for services** (API providers, SaaS platforms, cloud services)
- **Requesting API access** (developer programs, partner APIs)
- **Communicating with vendors** (support tickets, billing inquiries)
- **Receiving verification codes** (email verification, 2FA setup)
- **Account activation** (waiting for approval, responding to verification requests)

## Architecture

```text
Mission Orchestrator
    |
    v
mission-email-helper.sh
    |
    +-- send ---------> SES (aws ses send-raw-email)
    |                       |
    |                       v
    |                   Recipient inbox
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

### Receiving Email

SES can store inbound emails in S3 via receipt rules. The `receive` command polls an S3 bucket, downloads raw `.eml` files, parses them, matches them to conversation threads, and extracts verification codes.

**Setup requirements:**

1. SES receipt rule configured to store emails in S3
2. S3 bucket accessible with the same AWS credentials as the SES account
3. Domain MX records pointing to SES for the receiving domain

### Conversation Threading

Every email exchange is tracked as a **thread** in the SQLite database:

- **Thread ID**: Unique identifier (e.g., `thr-20260228-143022-a1b2c3d4`)
- **Mission ID**: Links the thread to a specific mission
- **Counterparty**: The external email address we're communicating with
- **Status**: `active` | `waiting` | `resolved` | `abandoned`

Inbound emails are matched to threads by:

1. `In-Reply-To` header matching a previous SES Message-ID
2. Sender email matching a thread's counterparty
3. If no match, a new thread is created

### Verification Code Extraction

The `extract-code` command and automatic extraction on `receive` detect:

| Pattern | Example | Type |
|---------|---------|------|
| Numeric codes | `Your code is 847291` | `numeric_code` |
| Alphanumeric tokens | `API key: sk_live_abc123def456` | `token` |
| Verification URLs | `https://example.com/verify?token=abc` | `verification_url` |
| Temporary passwords | `Temporary password: Xk9#mP2q` | `temporary_password` |

Extracted codes are stored in the database and can be retrieved by thread or message.

## Usage

### Sending Email

```bash
# Send using a template
mission-email-helper.sh send \
  --account production \
  --from noreply@yourdomain.com \
  --to api-support@vendor.com \
  --subject "API Access Request" \
  --template api-access-request \
  --var COMPANY_NAME="My Company" \
  --var USE_CASE="Automated integration" \
  --var SENDER_NAME="John Smith"

# Send plain text
mission-email-helper.sh send \
  --account production \
  --from noreply@yourdomain.com \
  --to support@vendor.com \
  --subject "Account Status" \
  --body "Please provide an update on our account application." \
  --thread-id thr-20260228-143022-a1b2c3d4
```

### Receiving Email

```bash
# Poll S3 for new emails
mission-email-helper.sh receive \
  --account production \
  --mailbox my-ses-bucket/inbound

# Only process recent emails for a specific thread
mission-email-helper.sh receive \
  --account production \
  --mailbox my-ses-bucket/inbound \
  --since 2026-02-28T00:00:00Z \
  --thread-id thr-20260228-143022-a1b2c3d4
```

### Parsing and Code Extraction

```bash
# Parse a raw email file
mission-email-helper.sh parse /path/to/email.eml

# Parse from stdin
cat email.eml | mission-email-helper.sh parse -

# Extract verification codes from text
echo "Your verification code is 847291" | mission-email-helper.sh extract-code -

# Extract from a file
mission-email-helper.sh extract-code /path/to/email-body.txt
```

### Thread Management

```bash
# Create a thread before starting communication
mission-email-helper.sh thread --create \
  --mission m001 \
  --subject "Stripe API Access" \
  --counterparty api-support@stripe.com \
  --context "Need API keys for payment processing integration"

# List all threads for a mission
mission-email-helper.sh thread --list --mission m001

# View full conversation with extracted codes
mission-email-helper.sh thread --show thr-20260228-143022-a1b2c3d4
```

### Templates

```bash
# List available templates
mission-email-helper.sh templates --list

# View a template
mission-email-helper.sh templates --show api-access-request
```

## Templates

Templates live in `~/.aidevops/agents/templates/email/` as `.txt` files. They use `{{KEY}}` placeholders.

### Built-in Templates

| Template | Purpose |
|----------|---------|
| `api-access-request` | Request developer/API access from vendors |
| `account-signup-followup` | Follow up on pending account approvals |
| `verification-response` | Respond to identity/business verification requests |
| `support-inquiry` | Technical support or billing questions |
| `generic` | Minimal template for custom messages |

### Creating Custom Templates

Create a `.txt` file in the templates directory:

```text
# Template Description - shown in template list
Hello {{RECIPIENT_NAME}},

{{BODY}}

Best regards,
{{SENDER_NAME}}
```

The first line (starting with `#`) is the template description. All `{{KEY}}` placeholders are replaced by `--var KEY=value` arguments.

## Mission Integration

### In Mission State File

Record email threads in the mission's Resources table:

```markdown
### Accounts & Credentials

| Service | Purpose | Status | Secret Key |
|---------|---------|--------|------------|
| Stripe | Payment processing | waiting | gopass:aidevops/stripe/api-key |

### External Dependencies

| Dependency | Type | Status | Notes |
|------------|------|--------|-------|
| Stripe API access | api | pending | Thread: thr-20260228-143022-a1b2c3d4 |
```

### Orchestrator Workflow

1. **Create thread**: Before first contact, create a thread linked to the mission
2. **Send email**: Use appropriate template with mission context
3. **Poll for responses**: Periodically run `receive` to check for replies
4. **Extract codes**: Verification codes are auto-extracted and stored
5. **Use credentials**: Pass extracted codes/tokens to `credential-helper.sh`
6. **Update thread status**: Mark as `resolved` when communication is complete

### Credential Handoff

When a verification code or API key is extracted from an email:

```bash
# Get the latest unused code from a thread
code=$(sqlite3 ~/.aidevops/.agent-workspace/mail/mission-email.db \
  "SELECT ec.code_value FROM extracted_codes ec
   JOIN messages m ON ec.message_id = m.id
   WHERE m.thread_id = 'thr-xxx' AND ec.used = 0
   ORDER BY ec.extracted_at DESC LIMIT 1;")

# Store in credential management
aidevops secret set VENDOR_API_KEY  # user enters the value

# Mark code as used
sqlite3 ~/.aidevops/.agent-workspace/mail/mission-email.db \
  "UPDATE extracted_codes SET used = 1
   WHERE code_value = '$code';"
```

## Security

- Email credentials are managed through `ses-config.json` (same as `ses-helper.sh`)
- Extracted codes and tokens are stored in the local SQLite database only
- The database file permissions should be 600 (owner read/write only)
- Never log or output full API keys or passwords in verbose mode
- Thread context may contain sensitive information -- treat the database as confidential

## Related

- `services/email/ses.md` -- SES provider guide
- `scripts/ses-helper.sh` -- SES management commands
- `scripts/credential-helper.sh` -- Multi-tenant credential storage
- `workflows/mission-orchestrator.md` -- Mission execution lifecycle
- `templates/mission-template.md` -- Mission state file format
