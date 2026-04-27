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

**Event kinds:** `open` | `status_change` | `attach` | `note` | `comm` | `deadline` | `party` | `archive` | `alarm`

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

## Drafting (P6a — t2857)

The drafting subsystem generates strategic communication drafts using RAG over case knowledge sources. All drafts are **human-gated** — they write to `_cases/<id>/drafts/` and never auto-send.

### Draft command

```bash
aidevops case draft <case-id> --intent "request payment of overdue invoice" \
    [--tone neutral|formal|conciliatory|firm] \
    [--length short|medium|long] \
    [--cite strict|loose] \
    [--include-case <other-case-id>] \
    [--dry-run] [--json]
```

### Revise command

```bash
aidevops case draft <case-id> --revise <draft-file> --feedback "soften paragraph 3"
```

Produces a new revision file (`-rev2.md`, `-rev3.md`, etc.) preserving the citation standard.

### Draft output

Drafts are written to `_cases/<case-id>/drafts/<timestamp>-<intent-slug>.md` with:

- **YAML frontmatter:** `case_id`, `intent`, `tone`, `length`, `model`, `generated_at`, `sources_consulted`, `cross_case_includes`
- **Body:** LLM output with `[source-id]` citation anchors
- **Provenance footer:** explicit list of source IDs with kind, sensitivity, and sha — always appended even if the model omits it

### Sensitivity-tier routing

The draft helper reads `meta.json` from each attached source to determine sensitivity. The **maximum sensitivity** across all sources determines the LLM routing tier:

| Source sensitivity | LLM routing tier | Provider |
|---|---|---|
| `public` | `public` | Any (default: Anthropic) |
| `internal` | `internal` | Cloud or local |
| `confidential` | `sensitive` | Local only (Ollama) |
| `restricted` | `privileged` | Local only; hard-fail if unavailable |

When any attached source is `restricted` (privileged tier), the draft **must** route through the local LLM (Ollama). If Ollama is not running, the draft fails rather than sending privileged content to a cloud provider.

### Cross-case privilege firewall

By default, each case's draft sees **only its own** `sources.toon`. Cross-case retrieval requires explicit opt-in:

```bash
aidevops case draft <case-id> --intent "..." --include-case <other-case-id>
```

Every cross-case access is:

1. **Audited** — appended to `_cases/<case-id>/comms/cross-case-access.jsonl`:

   ```json
   {"at":"2026-04-27T10:00:00Z","included_case":"case-2026-0002-related","included_by":"user","reason":"Draft intent: ..."}
   ```

2. **Logged in timeline** — a `cross-case-access` event records the inclusion

This ensures cross-case knowledge bleed is always a deliberate, traceable act — critical for matters with multiple unrelated cases where discovery concerns apply.

### Tone library

Four built-in tones: `neutral`, `formal`, `conciliatory`, `firm`. Custom tones can be added by copying `.agents/templates/draft-tones-config.json` to `_config/draft-tones.json` in the repo.

### No auto-send enforcement

The drafting helper has **no** `--send` or `--auto-send` flag. Drafts are written to the `drafts/` directory (gitignored by default) for human review. Sending is a separate, deliberate act outside the draft workflow.

## Deadline Alarming (P4c — t2853)

The case alarm routine (`case-alarm-helper.sh tick`) is a pulse-driven routine (r043, every 15 min) that scans all open cases, classifies each deadline by urgency stage, and fires alarms when a stage escalation is detected.

### Alarm stages

| Stage  | Default threshold | Action                                 |
|--------|------------------|----------------------------------------|
| green  | >30d             | No alarm                               |
| amber  | ≤30d             | Fire alarm channels                    |
| red    | ≤7d              | Fire alarm channels (higher priority)  |
| passed | deadline reached | Auto-close GH alarm issue              |

### Alarm channels

- **`gh-issue`** — opens a GitHub issue tagged `kind:case-alarm` with a stable title `Case alarm: <case-id> deadline <label>`. Re-ticks update via comment. Auto-closes when deadline passes.
- **`ntfy`** — POST to configured ntfy topic (priority: urgent for red, high for amber).
- **`email`** — stub for MVP; full send in P5.

### Stage memory

Alarm state is recorded in `_cases/.alarm-state.json` so repeated ticks at the same stage do not spam. A more-severe stage (escalation) triggers a new alarm.

```json
{ "case-2026-0001-acme-dispute": { "filing-deadline": "amber" } }
```

### Config file

Copy `.agents/templates/case-alarms-config.json` to `_config/case-alarms.json` to customise:

```json
{
  "stages_days": [30, 7, 1],
  "channels":    ["gh-issue", "ntfy"],
  "ntfy_topic":  "aidevops-case-alarms",
  "per_case_overrides": {
    "case-2026-0001-special": { "stages_days": [60, 14, 3] }
  }
}
```

Per-case overrides honour individual matter urgency profiles (e.g. statute-of-limitations deadlines need earlier warning).

### Manual trigger

```bash
aidevops case alarm-test <case-id>
```

Re-fires alarms for all deadlines on the case, bypassing stage memory. For testing and debugging.

### Routine entry

```
r043 Case deadline alarming repeat:cron(*/15 * * * *) ~1m run:scripts/case-alarm-helper.sh tick
```

## Dependencies

- **Provisioned by:** `aidevops case init`
- **Sources come from:** `_knowledge/sources/` (managed by knowledge plane, t2844)
- **Alarming reads:** `dossier.deadlines` (t2853 P4c — implemented)
- **Comms agent operates on:** cases (P6)
- **Filter→case-attach:** uses `aidevops case attach` (P5c)
- **Drafting uses:** `llm-routing-helper.sh` (t2847), `knowledge-index-helper.sh` (t2850)

<!-- AI-CONTEXT-END -->
