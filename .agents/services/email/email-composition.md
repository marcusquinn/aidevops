---
description: AI-assisted email composition — draft-review-send workflow, tone calibration, signature injection, attachment handling, CC/BCC logic, legal liability awareness
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Email Composition

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/email-compose-helper.sh [command] [options]`
- **Config**: `configs/email-compose-config.json` (from `.json.txt` template)
- **Drafts**: `~/.aidevops/.agent-workspace/email-compose/drafts/`
- **Sent**: `~/.aidevops/.agent-workspace/email-compose/sent/`

**Key principle**: AI composes, human reviews. No email is sent without explicit confirmation. Draft-and-hold is the default for all non-template emails.

**Quick commands:**

```bash
# Compose new email
email-compose-helper.sh draft --to client@example.com \
  --subject "Project Update" --context "phase 2 complete" --importance high

# Acknowledge receipt (brief, haiku-tier)
email-compose-helper.sh acknowledge --to support@vendor.com \
  --subject "Re: Your inquiry" --context "will respond within 24h"

# Follow up on delayed response
email-compose-helper.sh follow-up --to partner@example.com \
  --subject "Re: Proposal" --days-since 5

# Reminder for outstanding request
email-compose-helper.sh remind --to contractor@example.com \
  --subject "Invoice #1234" --original-date "2026-03-01"

# Preview without sending
email-compose-helper.sh draft --to test@example.com \
  --subject "Test" --context "test" --dry-run
```

<!-- AI-CONTEXT-END -->

## Commands

| Command | Purpose | Model |
|---------|---------|-------|
| `draft` | Compose new email — AI drafts, human reviews | sonnet/opus |
| `reply` | Compose reply (auto-detect reply vs reply-all) | sonnet/opus |
| `forward` | Forward with optional commentary | sonnet |
| `acknowledge` | Brief holding-pattern response | haiku |
| `follow-up` | Follow up when replying is delayed | sonnet |
| `remind` | Reminder for outstanding requests | sonnet |
| `notify` | Project update notification | sonnet |
| `list` | Show saved drafts (`--sent` for archive) | — |

## Model Routing

Model selection is based on `--importance`:

| Importance | Model | Use for |
|------------|-------|---------|
| `high` | opus | Client-facing, legal, important negotiations, sensitive topics |
| `normal` | sonnet | Routine correspondence, vendor communication, team updates |
| `low` | haiku | Acknowledgements, brief notifications, holding-pattern responses |

**Rationale**: Written communication quality has outsized impact on relationships. Opus-tier writing for important emails is cost-justified — a poorly worded client email can cost more than the model difference.

## Tone Calibration

Tone is auto-detected from the recipient's email domain if not specified:

- **Personal domains** (gmail.com, hotmail.com, yahoo.com, icloud.com, me.com): `casual`
- **Business domains** (everything else): `formal`

Override with `--tone formal` or `--tone casual`.

**Tone overrides by domain** can be configured in `email-compose-config.json`:

```json
{
  "tone_overrides": {
    "trusted-partner.com": "casual",
    "legal-firm.com": "formal"
  }
}
```

### Formal tone characteristics

- Full salutation: "Dear [Name],"
- Complete sentences, no contractions
- Professional closing: "Kind regards," / "Best regards,"
- Precise language, no ambiguity
- Explicit CTAs: "Please confirm by [date]"

### Casual tone characteristics

- Relaxed salutation: "Hi [Name],"
- Contractions acceptable
- Friendly closing: "Thanks," / "Cheers,"
- Direct and concise
- Conversational but still professional

## Composition Rules

These rules are injected into every AI composition prompt:

1. **One sentence per paragraph** — improves mobile readability and threading
2. **Clear subject line** — describes the email's purpose, not just the topic
3. **Numbered lists** for multiple questions or action items
4. **Explicit CTA** if a response is needed ("Please confirm by Friday")
5. **No urgency flags** unless the context explicitly requires it
6. **Overused phrase avoidance** — see list below
7. **Legal awareness** — distinguish agreed vs advised vs informational

## Overused Phrases (Auto-Flagged)

The helper detects and warns on these phrases:

| Phrase | Better alternative |
|--------|-------------------|
| "quick question" | Just ask the question directly |
| "just following up" | "I wanted to check on..." or state the specific ask |
| "just checking in" | State what you're checking on specifically |
| "hope this finds you well" | Skip the pleasantry, start with the purpose |
| "as per my last email" | Reference the specific point directly |
| "circle back" | "revisit" or "discuss" |
| "touch base" | "connect" or "discuss" |
| "reach out" | "contact" or "email" |
| "synergy" | Describe the actual benefit |
| "leverage" | "use" |
| "paradigm shift" | Describe the actual change |
| "move the needle" | State the specific metric or outcome |
| "low-hanging fruit" | "quick wins" or describe the specific task |
| "bandwidth" | "time" or "capacity" |
| "deep dive" | "detailed review" or "thorough analysis" |
| "at the end of the day" | State the actual conclusion |

## Legal Liability Awareness

Email creates a written record. Composition guidance for legally sensitive content:

### Distinguish clearly between:

**Agreed** — something contractually or verbally committed:
> "As agreed in our contract, delivery is scheduled for 15 March."

**Advised** — professional recommendation, not a guarantee:
> "Based on current information, I would advise proceeding with Option A. This is my professional recommendation, not a guarantee of outcome."

**Informational** — sharing information without commitment:
> "For your information, the current market rate is approximately £X. This is not a quote."

### Avoid:

- Admitting liability without legal review ("I'm sorry we caused this problem")
- Making commitments outside your authority ("We will definitely deliver by...")
- Speculating about outcomes ("This should work fine")
- Forwarding confidential information without checking permissions

### When in doubt:

- Use "I understand" rather than "I agree"
- Use "I'll look into this" rather than "We'll fix this"
- Add "subject to contract" for commercial commitments
- Consult legal before sending anything that could be used in a dispute

## CC/BCC Patterns

### When to CC

- **Transparency**: when others need visibility but no action is required
- **Escalation**: when copying a manager to show awareness
- **Handoff**: when introducing someone who will take over
- **Compliance**: when a record is required (e.g., HR, legal)

### When to BCC

- **Privacy**: when recipients shouldn't see each other's addresses (newsletters, group announcements)
- **Audit trail**: when you want a copy without the recipient knowing
- **Sensitive escalation**: copying a manager without alerting the recipient

### Reply vs Reply-All vs New Thread

| Situation | Action |
|-----------|--------|
| Response only relevant to sender | Reply (1:1) |
| Response relevant to all CC'd parties | Reply-all |
| New topic, even if related | New thread with clear subject |
| Sensitive content in a group thread | New 1:1 thread |
| Thread has grown stale (>2 weeks) | New thread with summary |

**Reply-all caution**: Before reply-all, check whether all CC'd parties need your response. Unnecessary reply-all is a common source of inbox noise.

## Attachment Handling

| Size | Action |
|------|--------|
| <25MB | Attach normally |
| 25–30MB | Warning — consider file-share link |
| >30MB | Blocked — must use file-share link |

### File-share alternatives

- **General files**: Google Drive, Dropbox, OneDrive
- **Confidential files**: [PrivateBin](https://privatebin.net) with self-destruct enabled
  - Set expiry: "1 week" or "after 1 read" for sensitive documents
  - Password-protect and share password via separate channel (phone/Signal)
- **Large media**: WeTransfer (free up to 2GB)

### Screenshot guidance

When attaching screenshots:
- Crop to show only the relevant information
- Remove personal data, credentials, or unrelated content from the frame
- Use annotation (arrows, highlights) to direct attention
- Prefer a single annotated screenshot over multiple raw ones

## Signature Injection

Signatures are injected automatically from:

1. **Config file** (`email-compose-config.json` `.signatures.<name>`)
2. **Signature file** (`configs/email-signature-<name>.txt`)
3. **Apple Mail parser** (`email-signature-parser-helper.sh get-default`)

Configure multiple signatures for different contexts:

```json
{
  "signatures": {
    "default": "Best regards,\nYour Name\nYour Title\nyour@email.com",
    "formal": "Yours sincerely,\nYour Full Name\nYour Title | Your Company\nT: +44 xxx xxx xxxx",
    "brief": "Thanks,\nYour Name"
  }
}
```

Use `--signature formal` to select a named signature.

## Draft-Review-Send Workflow

```text
email-compose-helper.sh draft --to ... --subject ... --context ...
    │
    ▼
1. AI COMPOSE
    ├── Tone detection (recipient domain or --tone)
    ├── Model selection (--importance)
    ├── Overused phrase check
    └── Signature injection
    │
    ▼
2. DRAFT SAVED
    └── ~/.aidevops/.agent-workspace/email-compose/drafts/draft-YYYYMMDD-HHMMSS-xxxx.md
    │
    ▼
3. HUMAN REVIEW (editor opens)
    ├── Edit freely — AI draft is a starting point
    ├── Save and close to continue
    └── Delete all content to abort
    │
    ▼
4. CONFIRM SEND
    ├── Shows To: and Subject:
    └── [y/N] prompt
    │
    ▼
5. SEND (via email-agent-helper.sh → SES)
    └── Draft archived to sent/
```

**Never auto-send**: The `--no-review` flag skips the editor but still requires explicit confirmation. The only way to bypass confirmation entirely is `--no-review` combined with piping `y` to stdin — which should only be used in tested automation scripts.

## Support and Customer Service Communication

When communicating with support teams or on behalf of customers:

### Understand receiver capabilities

- Support agents work from scripts — be specific about what you need
- Reference ticket/case numbers in every message
- State what you've already tried (avoids "have you tried turning it off and on again")
- Ask for escalation explicitly when tier-1 support is insufficient: "I'd like to escalate this to your technical team"

### Escalation patterns

```
Tier 1 → Tier 2: "I've been working with your support team on [ticket #X] for [N days].
The issue requires technical investigation beyond standard troubleshooting.
Please escalate to your technical team."

Tier 2 → Management: "This issue has been open for [N days] and is impacting [specific business function].
I'd like to speak with a manager or account manager to resolve this."
```

### Tone for support communication

- **Formal and factual** — emotions don't help, facts do
- **Specific** — exact error messages, timestamps, steps to reproduce
- **Documented** — reference previous ticket numbers and agent names
- **Persistent but professional** — follow up on schedule, not impulsively

## Configuration

### Config Template

Copy `configs/email-compose-config.json.txt` to `configs/email-compose-config.json` and customise.

Key settings:

```json
{
  "default_from_email": "you@yourdomain.com",
  "signatures": {
    "default": "Best regards,\nYour Name",
    "formal": "Yours sincerely,\nYour Full Name"
  },
  "tone_overrides": {
    "trusted-partner.com": "casual"
  },
  "default_importance": "normal"
}
```

## Related

- `scripts/email-compose-helper.sh` — CLI for composition workflow
- `services/email/email-agent.md` — Autonomous mission email (send/poll/extract)
- `services/email/email-mailbox.md` — Mailbox management and triage
- `content/distribution/email.md` — Subject line formulas, content strategy
- `marketing/direct-response-copy-frameworks-email-sequences.md` — Copywriting frameworks
- `scripts/email-signature-parser-helper.sh` — Apple Mail signature extraction
