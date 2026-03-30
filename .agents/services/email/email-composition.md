---
description: Email composition — draft-review-send workflow, tone calibration, signature injection, legal liability
mode: subagent
tools: { read: true, bash: true }
---

# Email Composition

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/email-compose-helper.sh [command] [options]`
- **Config**: `configs/email-compose-config.json` (copy from `.json.txt`; keys: `default_from_email`, `signatures`, `tone_overrides`, `default_importance`)
- **Drafts**: `~/.aidevops/.agent-workspace/email-compose/drafts/`
- **Sent**: `~/.aidevops/.agent-workspace/email-compose/sent/`

**Key principle**: AI composes, human reviews. No email sent without explicit confirmation.

```bash
email-compose-helper.sh draft --to client@example.com \
  --subject "Project Update" --context "phase 2 complete" --importance high
```

<!-- AI-CONTEXT-END -->

## Draft-Review-Send Workflow

1. **COMPOSE** — tone detection, model selection, phrase check, signature injection
2. **DRAFT** → `drafts/draft-YYYYMMDD-HHMMSS-xxxx.md`
3. **REVIEW** — editor opens; delete all content to abort
4. **CONFIRM** — shows To/Subject, `[y/N]` prompt
5. **SEND** via `email-agent-helper.sh → SES` — archived to `sent/`

`--no-review` skips editor but still requires confirmation. Full bypass (`--no-review` + piping `y`) for tested automation only.

## Commands and Model Routing

| Command | Purpose | Model |
|---------|---------|-------|
| `draft` / `reply` | Client-facing, legal, negotiations (`--importance high`) | opus |
| `draft` / `reply` | Routine correspondence, vendor comms | sonnet |
| `forward` | Forward with optional commentary | sonnet |
| `follow-up` / `remind` | Delayed replies, outstanding requests | sonnet |
| `notify` | Project update notification | sonnet |
| `acknowledge` | Brief holding-pattern response | haiku |
| `list` | Show drafts (`--sent` for archive) | — |

Opus is cost-justified — a poorly worded client email costs more than the model difference.

## Composition Rules

1. **One sentence per paragraph** — mobile readability
2. **Clear subject line** — purpose, not just topic
3. **Numbered lists** for multiple questions or action items
4. **Explicit CTA** when response needed ("Please confirm by Friday")
5. **No urgency flags** unless context requires it
6. **Legal awareness** — distinguish agreed vs advised vs informational

### Overused Phrases (Auto-Flagged)

| Avoid | Instead |
|-------|---------|
| "quick question" / "just following up" / "just checking in" | State the specific ask |
| "hope this finds you well" | Skip — start with purpose |
| "as per my last email" | Reference the specific point |
| "circle back" / "touch base" / "reach out" | "revisit" / "discuss" / "contact" |
| "synergy" / "leverage" / "paradigm shift" / "move the needle" | Describe the actual benefit or metric |
| "low-hanging fruit" / "bandwidth" / "deep dive" | "quick wins" / "capacity" / "detailed review" |

## Tone Calibration

Auto-detected from recipient domain; override with `--tone formal` or `--tone casual`.

| Tone | Domains | Salutation | Closing |
|------|---------|------------|---------|
| `casual` | gmail, hotmail, yahoo, icloud, me.com | "Hi [Name]," | "Thanks," / "Cheers," |
| `formal` | All other domains | "Dear [Name]," | "Kind regards," / "Best regards," |

Casual: contractions OK, direct. Formal: no contractions, explicit CTAs. Domain-level overrides via `tone_overrides` in config.

## CC/BCC and Threading

- **Reply** when only sender needs the response; **reply-all** when CC'd parties need it
- **New thread** for new topics, sensitive content in group threads, or stale threads (>2 weeks)

## Attachments

| Size | Action |
|------|--------|
| <25MB | Attach normally |
| 25–30MB | Warning — consider file-share link |
| >30MB | Blocked — must use file-share link |

File-share: Google Drive / Dropbox / OneDrive (general); [PrivateBin](https://privatebin.net) (confidential, self-destruct); WeTransfer (large media). Screenshots: crop, remove credentials, annotate.

## Signature Injection

Source priority: config file → signature file → Apple Mail parser. Select with `--signature formal`.

```json
{
  "signatures": {
    "default": "Best regards,\nYour Name\nYour Title\nyour@email.com",
    "formal": "Yours sincerely,\nYour Full Name\nYour Title | Your Company\nT: +44 xxx xxx xxxx",
    "brief": "Thanks,\nYour Name"
  }
}
```

## Legal Liability

Email creates a written record. Distinguish clearly:

- **Agreed** — committed: *"As agreed in our contract, delivery is scheduled for 15 March."*
- **Advised** — recommendation, not guarantee: *"I would advise Option A. This is my recommendation, not a guarantee of outcome."*
- **Informational** — no commitment: *"The current market rate is approximately £X. This is not a quote."*

**Avoid:** admitting liability without legal review; commitments outside authority; speculating on outcomes; forwarding confidential info without permission.

**Hedging:** "I understand" not "I agree"; "I'll look into this" not "We'll fix this"; "subject to contract" for commercial commitments.

## Support and Customer Service

Reference ticket numbers. State what you've tried. Tone: formal, factual — specific errors, timestamps, repro steps.

**Escalation:** *Tier 1→2:* "Working with support on [ticket #X] for [N days]. Requires technical investigation — please escalate." *Tier 2→Mgmt:* "Open [N days], impacting [business function]. I'd like to speak with a manager."

## Related

`scripts/email-compose-helper.sh` · `services/email/email-agent.md` (autonomous send/poll/extract) · `services/email/email-mailbox.md` (triage) · `content/distribution-email.md` (subject lines, content strategy) · `marketing-sales/direct-response-copy-frameworks-email-sequences.md` (copywriting) · `scripts/email-signature-parser-helper.sh` (Apple Mail parser)
