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

```bash
email-compose-helper.sh draft --to client@example.com \
  --subject "Project Update" --context "phase 2 complete" --importance high
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

Opus for important emails is cost-justified — a poorly worded client email costs more than the model difference.

## Tone Calibration

Auto-detected from recipient domain; override with `--tone formal` or `--tone casual`.

| Tone | Domains | Salutation | Closing | Style |
|------|---------|------------|---------|-------|
| `casual` | gmail, hotmail, yahoo, icloud, me.com | "Hi [Name]," | "Thanks," / "Cheers," | Contractions OK, direct |
| `formal` | All other domains | "Dear [Name]," | "Kind regards," / "Best regards," | No contractions, explicit CTAs |

Domain-level overrides: set `tone_overrides` in `email-compose-config.json`.

## Composition Rules

1. **One sentence per paragraph** — mobile readability and threading
2. **Clear subject line** — the email's purpose, not just the topic
3. **Numbered lists** for multiple questions or action items
4. **Explicit CTA** when response needed ("Please confirm by Friday")
5. **No urgency flags** unless context explicitly requires it
6. **Overused phrase avoidance** — see table below
7. **Legal awareness** — distinguish agreed vs advised vs informational

## Overused Phrases (Auto-Flagged)

| Avoid | Instead |
|-------|---------|
| "quick question" / "just following up" / "just checking in" | State the specific ask directly |
| "hope this finds you well" | Skip — start with purpose |
| "as per my last email" | Reference the specific point |
| "circle back" / "touch base" / "reach out" | "revisit" / "discuss" / "contact" |
| "synergy" / "leverage" / "paradigm shift" / "move the needle" | Describe the actual benefit, change, or metric |
| "low-hanging fruit" / "bandwidth" / "deep dive" / "at the end of the day" | "quick wins" / "capacity" / "detailed review" / state the conclusion |

## Legal Liability Awareness

Email creates a written record. Distinguish clearly:

- **Agreed** — contractually or verbally committed: *"As agreed in our contract, delivery is scheduled for 15 March."*
- **Advised** — professional recommendation, not a guarantee: *"I would advise proceeding with Option A. This is my recommendation, not a guarantee of outcome."*
- **Informational** — sharing without commitment: *"The current market rate is approximately £X. This is not a quote."*

**Avoid:** admitting liability without legal review; commitments outside authority; speculating about outcomes; forwarding confidential info without permission.

**Hedging language:** "I understand" not "I agree"; "I'll look into this" not "We'll fix this"; "subject to contract" for commercial commitments. Consult legal before anything usable in a dispute.

## CC/BCC Patterns

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

**File-share alternatives:** Google Drive / Dropbox / OneDrive (general); [PrivateBin](https://privatebin.net) (confidential, self-destruct, password via separate channel); WeTransfer (large media).

**Screenshots:** Crop to relevant content; remove credentials/personal data; annotate; prefer one annotated image over multiple raw ones.

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

1. **AI COMPOSE** — tone detection, model selection, overused phrase check, signature injection
2. **DRAFT SAVED** → `~/.aidevops/.agent-workspace/email-compose/drafts/draft-YYYYMMDD-HHMMSS-xxxx.md`
3. **HUMAN REVIEW** — editor opens; edit freely; delete all content to abort
4. **CONFIRM SEND** — shows To: and Subject:, `[y/N]` prompt
5. **SEND** via `email-agent-helper.sh → SES` — draft archived to `sent/`

**Never auto-send**: `--no-review` skips the editor but still requires confirmation. Full bypass (`--no-review` + piping `y`) is for tested automation scripts only.

## Support and Customer Service

Reference ticket numbers in every message. State what you've tried. Tone: formal, factual — specific errors, timestamps, repro steps. Follow up on schedule, not impulsively.

**Escalation:** *Tier 1→2:* "Working with support on [ticket #X] for [N days]. Requires technical investigation beyond standard troubleshooting — please escalate." *Tier 2→Mgmt:* "Open [N days], impacting [business function]. I'd like to speak with a manager to resolve this."

## Configuration

Copy `configs/email-compose-config.json.txt` → `configs/email-compose-config.json`. Key settings: `default_from_email`, `signatures`, `tone_overrides`, `default_importance`.

## Related

- `scripts/email-compose-helper.sh` — CLI for composition workflow
- `services/email/email-agent.md` — Autonomous mission email (send/poll/extract)
- `services/email/email-mailbox.md` — Mailbox management and triage
- `content/distribution-email.md` — Subject line formulas, content strategy
- `marketing-sales/direct-response-copy-frameworks-email-sequences.md` — Copywriting frameworks
- `scripts/email-signature-parser-helper.sh` — Apple Mail signature extraction
