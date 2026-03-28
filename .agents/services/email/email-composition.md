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
email-compose-helper.sh draft --to client@example.com \
  --subject "Project Update" --context "phase 2 complete" --importance high
email-compose-helper.sh acknowledge --to support@vendor.com \
  --subject "Re: Your inquiry" --context "will respond within 24h"
email-compose-helper.sh follow-up --to partner@example.com \
  --subject "Re: Proposal" --days-since 5
email-compose-helper.sh remind --to contractor@example.com \
  --subject "Invoice #1234" --original-date "2026-03-01"
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

| Importance | Model | Use for |
|------------|-------|---------|
| `high` | opus | Client-facing, legal, negotiations, sensitive topics |
| `normal` | sonnet | Routine correspondence, vendor communication, team updates |
| `low` | haiku | Acknowledgements, brief notifications, holding-pattern responses |

Opus-tier for important emails is cost-justified — a poorly worded client email costs more than the model difference.

## Tone Calibration

Auto-detected from recipient domain; override with `--tone formal` or `--tone casual`.

| Tone | Domains | Salutation | Closing | Style |
|------|---------|------------|---------|-------|
| `casual` | gmail, hotmail, yahoo, icloud, me.com | "Hi [Name]," | "Thanks," / "Cheers," | Contractions OK, direct |
| `formal` | All other domains | "Dear [Name]," | "Kind regards," / "Best regards," | No contractions, explicit CTAs |

Domain-level overrides: set `tone_overrides` in `email-compose-config.json`.

## Composition Rules

Injected into every AI composition prompt:

1. **One sentence per paragraph** — improves mobile readability and threading
2. **Clear subject line** — describes the email's purpose, not just the topic
3. **Numbered lists** for multiple questions or action items
4. **Explicit CTA** if a response is needed ("Please confirm by Friday")
5. **No urgency flags** unless the context explicitly requires it
6. **Overused phrase avoidance** — see list below
7. **Legal awareness** — distinguish agreed vs advised vs informational

## Overused Phrases (Auto-Flagged)

| Phrase | Better alternative |
|--------|-------------------|
| "quick question" | Just ask the question directly |
| "just following up" | "I wanted to check on..." or state the specific ask |
| "just checking in" | State what you're checking on specifically |
| "hope this finds you well" | Skip the pleasantry, start with the purpose |
| "as per my last email" | Reference the specific point directly |
| "circle back" / "touch base" | "revisit" / "connect" or "discuss" |
| "reach out" | "contact" or "email" |
| "synergy" / "leverage" | Describe the actual benefit / use "use" |
| "paradigm shift" / "move the needle" | Describe the actual change / specific metric |
| "low-hanging fruit" / "bandwidth" | "quick wins" / "time" or "capacity" |
| "deep dive" / "at the end of the day" | "detailed review" / state the actual conclusion |

## Legal Liability Awareness

Email creates a written record. Distinguish clearly:

- **Agreed** — contractually or verbally committed: *"As agreed in our contract, delivery is scheduled for 15 March."*
- **Advised** — professional recommendation, not a guarantee: *"I would advise proceeding with Option A. This is my recommendation, not a guarantee of outcome."*
- **Informational** — sharing without commitment: *"The current market rate is approximately £X. This is not a quote."*

**Avoid:** admitting liability without legal review; commitments outside your authority; speculating about outcomes; forwarding confidential information without checking permissions.

**When in doubt:** use "I understand" not "I agree"; "I'll look into this" not "We'll fix this"; add "subject to contract" for commercial commitments; consult legal before sending anything that could be used in a dispute.

## CC/BCC Patterns

**CC** — when others need visibility but no action is required; escalation, handoff, compliance.

**BCC** — when recipients shouldn't see each other (newsletters); audit trail; sensitive escalation.

| Situation | Action |
|-----------|--------|
| Response only relevant to sender | Reply (1:1) |
| Response relevant to all CC'd parties | Reply-all |
| New topic, even if related | New thread with clear subject |
| Sensitive content in a group thread | New 1:1 thread |
| Thread has grown stale (>2 weeks) | New thread with summary |

## Attachment Handling

| Size | Action |
|------|--------|
| <25MB | Attach normally |
| 25–30MB | Warning — consider file-share link |
| >30MB | Blocked — must use file-share link |

**File-share alternatives:** Google Drive / Dropbox / OneDrive for general files; [PrivateBin](https://privatebin.net) (self-destruct, password-protected, share password via separate channel) for confidential; WeTransfer for large media.

**Screenshots:** Crop to relevant content only; remove credentials/personal data; annotate with arrows or highlights; prefer one annotated image over multiple raw ones.

## Signature Injection

Injected automatically from (in order): config file → signature file → Apple Mail parser.

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
2. DRAFT SAVED → ~/.aidevops/.agent-workspace/email-compose/drafts/draft-YYYYMMDD-HHMMSS-xxxx.md
    │
    ▼
3. HUMAN REVIEW (editor opens) — edit freely; delete all content to abort
    │
    ▼
4. CONFIRM SEND — shows To: and Subject:, [y/N] prompt
    │
    ▼
5. SEND (via email-agent-helper.sh → SES) — draft archived to sent/
```

**Never auto-send**: `--no-review` skips the editor but still requires explicit confirmation. Bypassing confirmation entirely (`--no-review` + piping `y` to stdin) is for tested automation scripts only.

## Support and Customer Service Communication

- Reference ticket/case numbers in every message
- State what you've already tried (avoids redundant tier-1 troubleshooting)
- Ask for escalation explicitly: *"I'd like to escalate this to your technical team"*
- Tone: formal and factual — emotions don't help, facts do; be specific (exact errors, timestamps, steps to reproduce); follow up on schedule, not impulsively

**Escalation templates:**

- *Tier 1 → Tier 2:* "I've been working with your support team on [ticket #X] for [N days]. The issue requires technical investigation beyond standard troubleshooting. Please escalate to your technical team."
- *Tier 2 → Management:* "This issue has been open for [N days] and is impacting [specific business function]. I'd like to speak with a manager or account manager to resolve this."

## Configuration

Copy `configs/email-compose-config.json.txt` to `configs/email-compose-config.json`. Key settings: `default_from_email`, `signatures` (see Signature Injection above), `tone_overrides`, `default_importance`.

## Related

- `scripts/email-compose-helper.sh` — CLI for composition workflow
- `services/email/email-agent.md` — Autonomous mission email (send/poll/extract)
- `services/email/email-mailbox.md` — Mailbox management and triage
- `content/distribution-email.md` — Subject line formulas, content strategy
- `marketing-sales/direct-response-copy-frameworks-email-sequences.md` — Copywriting frameworks
- `scripts/email-signature-parser-helper.sh` — Apple Mail signature extraction
