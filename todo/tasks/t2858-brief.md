---
mode: subagent
---

# t2858: `aidevops case chase` (template-only, opt-in auto-send)

## Pre-flight

- [x] Memory recall: `template-only auto-send chaser opt-in` → no relevant lessons
- [x] Discovery: builds on cases plane (t2851/2/3) and email channel (t2854/5/6); SMTP send needs new helper
- [x] File refs verified: parent brief; `email-providers.json.txt` (SMTP host/port metadata), `case-helper.sh` (timeline append)
- [x] Tier: `tier:standard` — template substitution + SMTP send + opt-in gating; no LLM at send time

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P6 (AI comms agent)

## What

`aidevops case chase <case-id> --template <name>` sends a routine chaser email built from a template (no LLM at send time, only verified-data field substitution). Per-case opt-in via `dossier.toon: chasers_enabled: true`. Template library in `_config/case-chase-templates/<name>.eml.tmpl`. Send routes through SMTP credentials in gopass. Sent chasers are recorded in case timeline + `comms/sent.jsonl`.

**Concrete deliverables:**

1. `scripts/case-chase-helper.sh send <case-id> --template <name> [--to <email>] [--dry-run]` — substitutes data fields, sends via SMTP, records timeline
2. Templates at `_config/case-chase-templates/<name>.eml.tmpl` — RFC 5322 format with `{{field}}` placeholders
3. Field substitution: only verified data from dossier (parties, deadlines, attached invoice numbers, amounts, dates) — NEVER LLM-generated content
4. Opt-in gating: `dossier.toon.chasers_enabled` must be `true`; otherwise `chase` exits 1 with message
5. SMTP integration: credentials from gopass per `_config/mailboxes.json` (reuse t2855 mailbox config)
6. Send audit: `_cases/<case-id>/comms/sent.jsonl` records timestamp, template, recipient, message-id, sent-via mailbox-id; timeline entry too
7. CLI: `aidevops case chase <case-id> --template <name>`; `aidevops case chase-template add|list|test`
8. Bounce handling (MVP): if SMTP send fails, log error + retry once; second failure marks case status:hold + alarms via t2853

## Why

Most case work has routine touchpoints — "where's the invoice", "deadline reminder", "have you received this", "please confirm receipt". AI-drafted comms (P6a) for these is overkill and risks template drift. Template-only chasers handle the boring 80% with zero risk of LLM-introduced errors, and free human attention for the strategic 20% that P6a serves.

Opt-in per case is critical: some cases (e.g., active dispute) the user might not want auto-chase. Defaults are `chasers_enabled: false`, so explicit enabling is required.

LLM-free at send time is the safety guarantee: the human reviewed the template once when authoring it, the substitution is deterministic, the send is reproducible. No "LLM generated unexpected text in chaser" failure mode.

## How (Approach)

1. **Template format** — `_config/case-chase-templates/payment-reminder.eml.tmpl`:
   ```
   From: {{sender_email}}
   To: {{recipient_email}}
   Subject: Reminder: invoice {{invoice_number}} dated {{invoice_date}}
   
   Dear {{recipient_name}},
   
   This is a reminder that invoice {{invoice_number}} dated {{invoice_date}} for {{currency}} {{amount}} 
   remains outstanding. The original due date was {{due_date}}.
   
   Please advise on the status of this payment.
   
   Regards,
   {{sender_name}}
   ```
2. **Field resolution** — `case-chase-helper.sh _resolve_fields(case-id, template, recipient)`:
   - From dossier: `parties`, `kind`, `case_id`, `parties_self`, `parties_recipient`
   - From attached invoice (if any in `sources.toon` with `kind: invoice`): `invoice_number`, `invoice_date`, `due_date`, `amount`, `currency` (read from invoice's `extracted.json` from t2849)
   - From mailbox config: `sender_email`, `sender_name`
   - From `--to` flag or auto-detected recipient party email: `recipient_email`, `recipient_name`
   - Validate ALL fields resolved before substitution; missing field → exit 1 with explicit list
3. **Opt-in check** — read `dossier.toon.chasers_enabled`; if missing or false, exit 1 unless `--force` (which still requires `dossier.toon.chasers_enabled: false-with-force-allowed` — even more deliberate)
4. **SMTP send** — Python script `email_send.py` using stdlib `smtplib` + `email` module:
   - Connect to SMTP host (from `mailboxes.json` mailbox-id), STARTTLS
   - Auth with credentials from gopass
   - Compose `EmailMessage` from substituted template
   - Send, capture message-id
   - Return `{message_id, sent_at}` JSON
5. **Audit + timeline** — on success:
   - Append to `_cases/<case>/comms/sent.jsonl`: full record
   - `case-helper.sh _timeline_append <case> "comm" "{kind: chase, template, recipient, message_id}"`
6. **Failure handling** — bounce/SMTP error:
   - First failure: log to `comms/sent.jsonl` with `status: error`, `error: <message>`, retry-allowed
   - Configurable retry: `case-chase-helper.sh retry <case-id> <message-id>` for manual retry
   - Two consecutive failures on same case: set case status to `hold` and fire alarm via t2853 via direct `case-alarm-helper.sh fire <case-id> --reason "chase send failure"`
7. **Template management** — `chase-template add|list|test`:
   - `add` opens editor on a fresh template, validates RFC 5322 + placeholder syntax
   - `test --case <case-id> --template <name>`: dry-run substitution, output to stdout (no send)
   - `list`: shows all templates with description (first comment line)
8. **Tests** — covers happy path send (with mocked SMTP), missing-fields rejection, opt-in gating, dry-run no-send, retry, bounce-failure → hold transition

### Files Scope

- NEW: `.agents/scripts/case-chase-helper.sh`
- NEW: `.agents/scripts/email_send.py`
- NEW: `.agents/templates/case-chase-templates/{payment-reminder,deadline-reminder,receipt-acknowledge}.eml.tmpl` (3 starter templates)
- EDIT: `.agents/cli/aidevops` (add `case chase` and `case chase-template` subcommand groups)
- EDIT: `.agents/scripts/case-helper.sh` (initialise dossier with `chasers_enabled: false` by default)
- NEW: `.agents/tests/test-case-chase.sh`
- EDIT: `.agents/aidevops/cases-plane.md` (chasing section + opt-in policy)

## Acceptance Criteria

- [ ] `aidevops case chase <case-id> --template payment-reminder` substitutes fields, sends email, records timeline + sent.jsonl
- [ ] Case with `chasers_enabled: false`: chase exits 1 with friendly message
- [ ] Missing dossier field (e.g., no invoice attached, template needs invoice_number): chase exits 1 with explicit list of missing fields, NO partial send
- [ ] `--dry-run` outputs the substituted email to stdout, no SMTP call
- [ ] Sent email records full message_id in audit log; recoverable in case timeline `show`
- [ ] LLM is never invoked during send (no `llm-routing-helper.sh` calls in this helper)
- [ ] SMTP send failure: first failure logs error + retry-allowed; second failure transitions case to `hold` + fires alarm
- [ ] `aidevops case chase-template test --case <id> --template <name>`: dry-run substitution shows the would-send email
- [ ] `aidevops case chase-template list` shows all templates with description
- [ ] Adding new template: opens editor, validates RFC 5322 + placeholder syntax before saving
- [ ] Credentials never logged or appear in any output (verifiable by grep over logs)
- [ ] ShellCheck zero violations; Python `py_compile` passes
- [ ] Tests pass: `bash .agents/tests/test-case-chase.sh`
- [ ] Documentation: chasing + opt-in policy in `.agents/aidevops/cases-plane.md`

## Dependencies

- **Blocked by:** t2851 (P4a — dossier with `chasers_enabled` field), t2852 (P4b — case-helper.sh timeline functions), t2849 (P1a — extracted.json invoice fields), t2855 (P5b — `mailboxes.json` for SMTP creds), t2853 (P4c — alarming integration on consecutive failures)
- **Soft-blocked by:** none (template-only, no RAG dependency)
- **Blocks:** none (final P6 leaf — closes MVP)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "AI comms agent" → strategic vs routine split
- Email config substrate: `.agents/configs/email-providers.json.txt` (SMTP host/port; reuse for sending)
- Pattern: similar to git hook templates — known structure, opt-in placement, deterministic firing
- Counterpart: t2857 (P6a) handles the LLM-drafted strategic side; this is the deterministic routine side
