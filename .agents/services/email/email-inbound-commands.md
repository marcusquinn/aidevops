---
description: Inbound email command interface - permitted senders can create tasks and request status replies through email with mandatory injection scanning
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Inbound Email Commands

## Purpose

Inbound email commands let permitted senders trigger aidevops task creation and receive confirmation replies without using the terminal. This interface is security-first: sender allowlist, mandatory prompt-injection scanning, and executable attachment blocking.

## Helper Script

- `scripts/email-inbound-command-helper.sh`
- Core command:

```bash
scripts/email-inbound-command-helper.sh poll --mailbox INBOX --limit 10
```

## Security Model

1. **Allowlist gate**
   - Only senders listed in `~/.config/aidevops/email-inbound-commands.conf` are processed.
   - Unknown senders are rejected, logged, and replied to with a denial message.

2. **Mandatory prompt-injection scanning**
   - Subject and body are scanned with `prompt-guard-helper.sh scan-stdin` before any action.
   - Emails with scanner findings are rejected and logged as security events.

3. **Executable attachment blocklist**
   - Dangerous attachment extensions are rejected (`.exe`, `.js`, `.docm`, `.app`, etc.).
   - No executable attachments are processed, ever.

4. **Audit trail**
   - Security-relevant events use `audit-log-helper.sh` when available.
   - Includes unauthorized sender attempts and injection detections.

## Configuration

Create `~/.config/aidevops/email-inbound-commands.conf`:

```text
# sender|permission|description
admin@example.com|admin|Primary administrator
ops@example.com|operator|Operations mailbox
pm@example.com|reporter|Project manager
```

Permissions:

- `admin` - full privileged sender
- `operator` - operational requests
- `reporter` - task creation requests
- `readonly` - non-mutating requests

## Command Interface

```bash
# Poll and process newest messages
scripts/email-inbound-command-helper.sh poll --mailbox INBOX --limit 10

# Poll a mailbox in a specific account
scripts/email-inbound-command-helper.sh poll --mailbox INBOX --account "Work" --limit 20

# Dry run (no task creation, no send)
scripts/email-inbound-command-helper.sh poll --mailbox INBOX --limit 5 --dry-run

# Check sender allowlist status
scripts/email-inbound-command-helper.sh sender-check user@example.com
```

## Request Handling

- **Task requests**
  - Parsed from inbound email content.
  - Task creation uses `claim-task-id.sh`.
  - Sender receives confirmation with task ID.

- **Question requests**
  - Status/help questions receive bounded, deterministic responses.
  - Intended for lightweight operational query/ack flows.

## Operational Notes

- Polling currently uses Apple Mail integration on macOS.
- Processed message IDs are tracked in `~/.aidevops/.agent-workspace/email-inbound-commands/processed-message-ids.txt` to prevent duplicate processing.
- If `email-compose-helper.sh` is present, replies use it; otherwise replies fall back to `apple-mail-helper.sh send`.

## Troubleshooting

- `Config not found`
  - Create `~/.config/aidevops/email-inbound-commands.conf` with allowlist entries.

- `Rejected unauthorized sender`
  - Add sender to allowlist and rerun poll.

- `Prompt injection findings`
  - Ask sender to resend plain text instructions without role/system override language.

- `Blocked executable attachment`
  - Ask sender to remove executable/macro attachments and resend.
