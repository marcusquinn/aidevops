---
description: AI-assisted email composition — draft-review-send workflow, tone calibration, signature injection, attachment handling, CC/BCC logic, legal liability awareness
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email Composition

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `email-compose-helper.sh [command] [options]`
- **Config**: `configs/email-compose-config.json` (copy from `.json.txt` template; key settings: `default_from_email`, `signatures`, `tone_overrides`, `default_importance`)
- **Drafts**: `~/.aidevops/.agent-workspace/email-compose/drafts/`
- **Sent**: `~/.aidevops/.agent-workspace/email-compose/sent/`

**Key principle**: AI composes, human reviews. No email sent without explicit confirmation.

```bash
email-compose-helper.sh draft --to client@example.com \
  --subject "Project Update" --context "phase 2 complete" --importance high
```

<!-- AI-CONTEXT-END -->

## Draft-Review-Send Workflow

1. **COMPOSE** — tone detection, model selection, overused phrase check, signature injection
2. **DRAFT** → `drafts/draft-YYYYMMDD-HHMMSS-xxxx.md`
3. **REVIEW** — editor opens; delete all content to abort
4. **CONFIRM** — shows To/Subject, `[y/N]` prompt
5. **SEND** via `email-agent-helper.sh → SES` — archived to `sent/`

`--no-review` skips editor but still requires confirmation. Full bypass (`--no-review` + piping `y`) for tested automation only.

## Commands and Model Routing

| Command | Purpose | Model |
|---------|---------|-------|
| `draft` | Compose new email | opus |
| `reply` | Reply (auto-detect reply vs reply-all) | opus |
| `forward` | Forward with optional commentary | sonnet |
| `follow-up` | Follow up on delayed reply | sonnet |
| `remind` | Reminder for outstanding requests | sonnet |
| `notify` | Project update notification | sonnet |
| `acknowledge` | Brief holding-pattern response | haiku |
| `list` | Show drafts (`--sent` for archive) | — |

`--importance high` routes to opus for client-facing, legal, negotiations, sensitive topics.

## Composition Rules

1. **One sentence per paragraph** — mobile readability
2. **Clear subject line** — state purpose, not just topic
3. **Numbered lists** for multiple questions/action items
4. **Explicit CTA** when response needed
5. **No urgency flags** unless context requires it
6. **Avoid overused phrases** (auto-flagged):

| Avoid | Instead |
|-------|---------|
| "quick question" / "just following up" / "just checking in" | State the ask directly |
| "hope this finds you well" | Skip — start with purpose |
| "as per my last email" | Reference the specific point |
| "circle back" / "touch base" / "reach out" | "revisit" / "discuss" / "contact" |
| "synergy" / "leverage" / "paradigm shift" / "move the needle" | Describe the actual benefit or metric |
| "low-hanging fruit" / "bandwidth" / "deep dive" | "quick wins" / "capacity" / "detailed review" |

7. **Legal awareness** — distinguish agreed vs advised vs informational (see Legal section)

## Tone Calibration

Auto-detected from recipient domain; override with `--tone formal|casual`.

| Tone | Domains | Salutation | Closing | Style |
|------|---------|------------|---------|-------|
| `casual` | gmail, hotmail, yahoo, icloud, me.com | "Hi [Name]," | "Thanks," / "Cheers," | Contractions OK, direct |
| `formal` | All other domains | "Dear [Name]," | "Kind regards," / "Best regards," | No contractions, explicit CTAs |

Per-domain overrides: `tone_overrides` in config.

## CC/BCC Patterns

| Situation | Action |
|-----------|--------|
| Response only relevant to sender | Reply (1:1) |
| Response relevant to all CC'd | Reply-all |
| New topic, even if related | New thread with clear subject |
| Sensitive content in group thread | New 1:1 thread |
| Thread stale >2 weeks | New thread with summary |

## Attachment Handling

| Size | Action |
|------|--------|
| <25MB | Attach normally |
| 25–30MB | Warning — consider file-share link |
| >30MB | Blocked — use file-share link |

File-share: Google Drive / Dropbox / OneDrive (general); [PrivateBin](https://privatebin.net) (confidential, self-destruct); WeTransfer (large media). Screenshots: crop, remove credentials, annotate.

## Signature Injection

Auto-injected from: config file → signature file → Apple Mail parser. Select with `--signature formal`.

```json
{
  "signatures": {
    "default": "Best regards,\nYour Name\nYour Title\nyour@email.com",
    "formal": "Yours sincerely,\nYour Full Name\nYour Title | Your Company\nT: +44 xxx xxx xxxx",
    "brief": "Thanks,\nYour Name"
  }
}
```

## Legal Liability Awareness

Email creates a written record. Distinguish clearly:

- **Agreed** — contractually committed: *"As agreed in our contract, delivery is scheduled for 15 March."*
- **Advised** — recommendation, not guarantee: *"I would advise Option A. This is my recommendation, not a guarantee."*
- **Informational** — no commitment: *"The current market rate is approximately £X. This is not a quote."*

**Avoid:** admitting liability without legal review; commitments outside authority; speculating on outcomes; forwarding confidential info without permission.

**Hedging:** "I understand" not "I agree"; "I'll look into this" not "We'll fix this"; "subject to contract" for commercial commitments.

## Support and Customer Service

Reference ticket numbers. State what you've tried. Formal, factual tone — specific errors, timestamps, repro steps.

**Escalation:** *Tier 1→2:* "Working with support on [ticket #X] for [N days]. Requires technical investigation — please escalate." *Tier 2→Mgmt:* "Open [N days], impacting [business function]. I'd like to speak with a manager."

## Related

- `services/email/email-agent.md` — Autonomous email (send/poll/extract)
- `services/email/email-mailbox.md` — Mailbox management and triage
- `content/distribution-email.md` — Subject line formulas, content strategy
- `marketing-sales/direct-response-copy-frameworks-email-sequences.md` — Copywriting frameworks
- `scripts/email-compose-helper.sh` — CLI usage
- `scripts/email-signature-parser-helper.sh` — Apple Mail signature extraction
