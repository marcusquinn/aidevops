# Cases Plane

<!-- AI-CONTEXT-START -->

The cases plane (`_cases/`) is an audit-trail-driven matter management system for legal, compliance, dispute, and operational case work. Each case is a directory with a structured dossier, a chronological timeline, pointers to attached knowledge sources, and sub-files for notes, communications, and drafts.

## Directory Contract

```
_cases/
├── .gitignore          # Excludes drafts/ by default
├── .case-counter       # Per-repo sequential counter: YYYY:NNNN
├── README.md
├── archived/           # Closed/archived cases (git mv from active)
└── case-YYYY-NNNN-<slug>/
    ├── dossier.toon    # ToonSON (JSON) metadata file
    ├── timeline.jsonl  # Chronological event log (one JSON per line)
    ├── sources.toon    # JSON array of attached knowledge source pointers
    ├── notes/
    │   └── notes.md   # Internal context notes
    ├── comms/
    │   └── comms.log  # Communications log (paper-trail entries)
    └── drafts/         # Work-in-progress (gitignored by default)
```

### Case ID Scheme

Format: `case-YYYY-NNNN-<slug>`

- `YYYY` — 4-digit year (resets sequence on year change)
- `NNNN` — zero-padded 4-digit sequence number per repo per year
- `<slug>` — kebab-case human identifier (e.g. `acme-dispute`, `gdpr-audit-2026`)

Example: `case-2026-0001-acme-dispute`

The counter is stored at `_cases/.case-counter` in format `YYYY:N` and incremented atomically via an `mkdir` lock to prevent collisions in concurrent sessions.

## dossier.toon Schema

The dossier is a plain JSON file (`.toon` indicates ToonSON — human-friendly versioned JSON config). See `.agents/templates/case-dossier-schema.json` for the JSON Schema.

```json
{
  "id":              "case-2026-0001-acme-dispute",
  "slug":            "acme-dispute",
  "kind":            "dispute",
  "opened_at":       "2026-04-26T00:00:00Z",
  "status":          "open",
  "outcome":         "",
  "outcome_summary": "",
  "parties": [
    {"name": "ACME Ltd", "role": "client"}
  ],
  "deadlines": [
    {"label": "filing deadline", "date": "2026-08-31"}
  ],
  "related_cases":  [],
  "related_repos":  []
}
```

**Status values:** `open` | `hold` | `closed`

**Outcome values (when closed):** free-text — e.g. `settled`, `withdrawn`, `resolved`, `dismissed`, `referred`

## timeline.jsonl Format

Each line is a JSON event object. Timeline is append-only — no event is ever deleted.

```json
{"ts":"2026-04-26T00:00:00Z","kind":"open","actor":"Marcus Quinn","content":"Case opened: case-2026-0001-acme-dispute","ref":""}
{"ts":"2026-04-26T10:00:00Z","kind":"attach","actor":"Marcus Quinn","content":"Attached source: src-001 (role: evidence)","ref":"src-001"}
{"ts":"2026-04-26T11:00:00Z","kind":"status_change","actor":"Marcus Quinn","content":"Status changed: open → hold. Reason: awaiting client","ref":""}
{"ts":"2026-04-26T12:00:00Z","kind":"note","actor":"Marcus Quinn","content":"Reviewed contract terms","ref":"notes/notes.md"}
{"ts":"2026-04-26T13:00:00Z","kind":"comm","actor":"Marcus Quinn","content":"Comm logged: in via email — Received settlement offer","ref":"comms/comms.log"}
{"ts":"2026-04-26T14:00:00Z","kind":"deadline","actor":"Marcus Quinn","content":"Deadline added: filing deadline on 2026-08-31","ref":""}
{"ts":"2026-04-26T15:00:00Z","kind":"party","actor":"Marcus Quinn","content":"Party added: Opposing Counsel (opponent)","ref":""}
{"ts":"2026-04-27T09:00:00Z","kind":"status_change","actor":"Marcus Quinn","content":"Case closed. Outcome: settled. Agreed in mediation","ref":""}
{"ts":"2026-04-27T09:01:00Z","kind":"archive","actor":"Marcus Quinn","content":"Case archived","ref":""}
```

**Event kinds:** `open` | `status_change` | `attach` | `note` | `comm` | `deadline` | `party` | `archive`

## sources.toon Format

Plain JSON array. Each entry is a pointer to a `_knowledge/sources/<id>/` directory — no content duplication.

```json
[
  {"id": "src-001", "attached_at": "2026-04-26T10:00:00Z", "attached_by": "Marcus Quinn", "role": "evidence"},
  {"id": "src-002", "attached_at": "2026-04-26T10:01:00Z", "attached_by": "Marcus Quinn", "role": "background"}
]
```

**Roles:** `evidence` | `reference` | `background`

**Cross-case privilege firewall (design only — enforced in P6a):** by default each case sees only its own `sources.toon`. Cross-case search will require explicit `--include-case <id>` and will be logged in the timeline.

## CLI Reference

Provided by `case-helper.sh`. Route via `aidevops case <subcommand>`.

### Provisioning

```bash
aidevops case init [<repo-path>]
```

Creates `_cases/`, `.case-counter`, `.gitignore`, `archived/`, and `README.md`. Safe to run on existing repos.

### Open a case

```bash
aidevops case open <slug> [--kind <type>] [--party <name>] [--party-role <role>] \
  [--deadline <ISO-date>] [--deadline-label <text>] [--json]
```

### View cases

```bash
aidevops case list [--status open|hold|closed|archived|all] [--kind <type>] [--party <name>] [--json]
aidevops case show <case-id> [--json]
```

### Lifecycle operations

```bash
aidevops case status <case-id> <open|hold> [--reason "..."] [--json]
aidevops case close <case-id> --outcome <outcome> [--summary "..."] [--json]
aidevops case archive <case-id> [--json]
```

**Closing requires `--outcome`** — attempting `case close` without it returns an error.

### Attach a knowledge source

```bash
aidevops case attach <case-id> <source-id> [--role evidence|reference|background] [--json]
```

Source must exist in `_knowledge/sources/<id>/` (promoted from inbox/staging). Refuses to attach non-promoted sources.

### Notes

```bash
aidevops case note <case-id> --message "Internal context here" [--json]
```

Appends to `notes/notes.md` AND timeline (timeline points to file location).

### Deadlines

```bash
aidevops case deadline add    <case-id> --date 2026-08-31 --label "filing deadline" [--json]
aidevops case deadline remove <case-id> --label "filing deadline" [--json]
```

### Parties

```bash
aidevops case party add    <case-id> --name "Opposing Counsel" --role "opponent" [--json]
aidevops case party remove <case-id> --name "Opposing Counsel" [--json]
```

### Communications log

```bash
aidevops case comm log <case-id> --direction in|out --channel email --summary "Received offer" [--json]
```

Paper-trail entry — full email content attaches via P5 (inbox-to-case filter). Each entry lands in `comms/comms.log` and the timeline.

## Archived Cases

`archive` uses `git mv` (when inside a git repo) to move the case directory to `_cases/archived/`. Archived cases:

- Are excluded from the default `list` output
- Are visible with `--status archived` or `--status all`
- Require `--unarchive` flag for all mutating operations

## JSON Output Mode

All read-side commands (`list`, `show`) and all mutating commands support `--json` for machine consumption. Use for scripting, P5 filter integration, and P4c alarming.

## Deadline Alarming (P4c — t2853)

The alarming subsystem reads `dossier.deadlines` from every open case on each pulse tick and fires notifications when a deadline enters a configured urgency stage.

### Alarm stages

Default config (`.agents/templates/case-alarms-config.json` → `_config/case-alarms.json`):

| Stage | Days remaining | Action |
|-------|---------------|--------|
| green | > 30 | No alarm |
| amber | 8–30 | Alarm fired |
| red   | ≤ 7  | Alarm fired (escalation from amber) |
| passed | < 0 | Alarm issue auto-closed |

Stage thresholds are configurable via `stages_days` in the config. Per-case overrides are supported under `per_case_overrides.<case-id>.stages_days`.

### Alarm channels

- **gh-issue** — opens a GitHub issue tagged `kind:case-alarm` with a stable title (`Case alarm: <case-id> deadline <label>`). Re-ticking at the same stage updates the issue comment, not a duplicate. Auto-closes when deadline passes.
- **ntfy** — POST to the configured ntfy topic via `curl`. Server configurable via `AIDEVOPS_NTFY_SERVER` env var (default: `https://ntfy.sh`).
- **email** — stub for MVP; full send in P5.

### Alarm state

`_cases/.alarm-state.json` records the last-alarmed stage per `(case-id, deadline-label)` pair. Re-ticking at the same stage is a no-op. Escalation (amber → red) fires a new alarm and updates the state.

```json
{ "case-2026-0001-acme-dispute": { "filing-deadline": { "stage": "amber", "gh_issue": 12345 } } }
```

### CLI commands

```bash
# Manual test (force-fires all alarms for a case, does NOT update alarm state)
aidevops case alarm-test <case-id> [<repo-path>]

# Direct helper (pulse routine)
case-alarm-helper.sh tick [<repo-path>]
```

### Routine

`r043` runs every 15 minutes via the pulse:

```
r043 Case deadline alarming repeat:cron(*/15 * * * *) ~1m run:scripts/case-alarm-helper.sh tick
```

### Config reference

```json
{
  "stages_days": [30, 7],
  "channels":    ["gh-issue", "ntfy"],
  "ntfy_topic":  "aidevops-case-alarms",
  "per_case_overrides": {
    "case-2026-0001-foo": { "stages_days": [60, 14, 3] }
  }
}
```

Copy `.agents/templates/case-alarms-config.json` to `_config/case-alarms.json` in the repo to activate. The helper creates a default config on first `tick` if none exists.

## Chasing (P6b — t2858)

Template-only, deterministic chaser emails. No LLM at send time.

### Opt-in policy

Chasers are **disabled by default** per case. `dossier.toon` is initialised with `chasers_enabled: false`.

Set `chasers_enabled: true` in `dossier.toon` before using `aidevops case chase`. This is a deliberate opt-in: cases in active dispute or sensitive negotiation should not be auto-chased.

Three valid values:

| Value | Behaviour |
|-------|-----------|
| `false` | Blocked (default). Chase exits 1 with a friendly message. |
| `true` | Allowed. All templates may be sent. |
| `false-with-force-allowed` | Blocked by default; `--force` overrides (requires deliberate flag). |

### Templates

Located at `.agents/templates/case-chase-templates/<name>.eml.tmpl`.

Format: RFC 5322 headers (`From:`, `To:`, `Subject:`) followed by a blank line, then body. Comments (lines starting with `#`) are stripped before substitution.

Placeholder syntax: `{{field_name}}`. All placeholders must resolve — any missing field causes an exit 1 before any SMTP call.

Starter templates:

| Template | Description |
|----------|-------------|
| `payment-reminder` | Invoice outstanding — polite initial chase |
| `deadline-reminder` | Upcoming or past deadline — action required |
| `receipt-acknowledge` | Confirm receipt of document or correspondence |

### CLI

```bash
# Send a chaser (case must have chasers_enabled: true)
aidevops case chase <case-id> --template payment-reminder

# Dry-run: show substituted email without sending
aidevops case chase <case-id> --template payment-reminder --dry-run

# Template management
aidevops case chase-template list
aidevops case chase-template test --case <case-id> --template payment-reminder
aidevops case chase-template add my-custom-template
```

### Audit

Every send (success or failure) appends to `_cases/<case-id>/comms/sent.jsonl`:

```json
{"ts":"...", "case_id":"...", "template":"payment-reminder", "recipient":"...",
 "mailbox_id":"...", "message_id":"<...@...>", "status":"sent"}
```

A timeline event (`kind: chase_sent` or `kind: chase_error`) is also appended.

### Failure handling

- **First failure:** logged with `status: error`, `retry_allowed: true`. Manual retry via `aidevops case chase retry <case-id> <message-id>`.
- **Second consecutive failure:** case status set to `hold` + alarm fired via `case-alarm-helper.sh fire` (if available).

### SMTP credentials

SMTP host/port resolved from `_config/mailboxes.json` (per-repo) or `~/.config/aidevops/mailboxes.json` (global). Provider SMTP settings auto-detected from `email-providers.json.txt` using the mailbox `provider` field.

Credentials fetched at send-time from `gopass` (via `password_ref: gopass:aidevops/email/<id>/password`). Never stored in logs or output.

## Dependencies

- **Provisioned by:** `aidevops case init`
- **Sources come from:** `_knowledge/sources/` (managed by knowledge plane, t2844)
- **Alarming reads:** `dossier.deadlines` (t2853 P4c)
- **Comms agent operates on:** cases (P6)
- **Filter→case-attach:** uses `aidevops case attach` (P5c)
- **Chase send:** `case-chase-helper.sh` (t2858 P6b) — template-only, no LLM

<!-- AI-CONTEXT-END -->
