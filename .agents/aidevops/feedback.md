<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feedback Plane

The `_feedback/` plane retains qualitative signal before it becomes durable
knowledge, campaign research, project requirements, case notes, performance
context, or TODO/GitHub work. It is separate from `_inbox/` because inboxes are
staging queues, and separate from `_knowledge/` because raw feedback is evidence,
not an approved insight.

For shared plane metadata, use `.agents/configs/data-planes.json` when a registry
entry exists. This document owns feedback mining, CLI, and routine design; capture
and retention details stay with the feedback capture and sensitivity contracts.

## Mining Loop

Mining MUST be recoverable from cold start. Each stage reads the current capture
set and writes only reviewed intermediate records or promotion decisions, so a
failed run can restart by re-reading captures plus any existing reviewed themes.

1. **Collect candidates** — select captures whose retention policy allows mining
   and whose sensitivity tier allows the current agent/model to inspect them.
   Exclude deleted, expired, privileged-without-approval, and source-revoked
   captures.
2. **Normalize** — redact private details, canonicalize source/channel labels,
   extract actor segment, time window, product/project area, sentiment, and any
   linked case/project/campaign IDs. Preserve the original capture ID and a hash
   of the redacted excerpt.
3. **Cluster** — group semantically related feedback by problem, desired outcome,
   audience segment, product area, and lifecycle moment. Clusters are working
   sets, not promoted themes.
4. **Deduplicate** — collapse repeated captures from the same actor, same thread,
   same import, or syndicated source into one evidence unit. Keep every source
   link internally, but count duplicates once for threshold purposes.
5. **Extract themes** — write a concise theme statement from the cluster:
   observed pain/opportunity, affected segment, scope, severity, confidence, and
   candidate promotion path.
6. **Attach evidence** — include source capture IDs, redacted excerpts, count of
   independent actors, time span, channel mix, affected area, sensitivity tier,
   and any contradicting or neutral feedback.
7. **Review** — apply the gates in this document before any theme becomes durable
   knowledge, a requirement, campaign input, case note, performance annotation, or
   TODO/GitHub task.
8. **Promote or retire** — promote approved themes to the target plane with
   back-links to source captures, or retire low-confidence clusters with a reason
   and recheck date.

## Evidence Thresholds

Signal strength is based on independent evidence units after deduplication, not
raw comment count.

| Signal type | Threshold | Default outcome |
|-------------|-----------|-----------------|
| One-off comment | 1 independent evidence unit, low/normal severity | Retain as context; do not auto-create a task |
| Repeated pattern | 3+ independent actors or sources within a relevant time window | Eligible for theme review and knowledge/promotion |
| Explicit maintainer/client request | Named maintainer/client asks for a change or decision | Eligible for review with lower count threshold |
| High-severity signal | Security, legal, safety, data loss, payment, accessibility blocker, or reputational risk | Escalate for review even from a single evidence unit |
| Contradicted signal | Meaningful opposing feedback or metrics conflict with the theme | Keep as research; require human review before promotion |

Severity can lower the count threshold, but it does not remove review. A single
severe report can justify escalation; it should not become an autonomous code or
policy change without the relevant gate.

## Review Gates

Mining gates protect users from noisy automation and protect private feedback
from leaking into durable public surfaces.

- **Sensitivity gate:** confidential, restricted, client-identifying, privileged,
  or personal feedback needs redaction and an approved target plane before
  promotion. Public GitHub surfaces receive summaries only, never raw private
  excerpts.
- **Single-comment gate:** one low/normal-severity comment can enrich context but
  MUST NOT auto-create a TODO/GitHub task. It needs either repetition, explicit
  maintainer/client request, or high-severity escalation.
- **Evidence gate:** promoted themes must cite independent evidence count,
  capture IDs, time span, and confidence. Missing provenance means the theme
  remains draft research.
- **Contradiction gate:** themes with conflicting feedback, weak metrics, or
  unclear segment ownership require review before promotion.
- **Task-creation gate:** TODO/GitHub tasks require a worker-ready body: files or
  decision surface, reference pattern, verification, and a privacy-safe summary of
  the evidence. Sensitive source links stay in `_feedback/`, not the public issue.

## Promotion Paths

Approved mined themes route to the smallest durable surface that can use them:

- `_knowledge/insights/` for durable cross-project learnings and reusable user or
  market insights.
- `_campaigns/active/<id>/research/` for audience pains, objections, language,
  and messaging opportunities.
- `_projects/<id>/requirements/` for validated product or delivery requirements.
- `_cases/<id>/feedback/` or case notes for client-specific signal that should not
  become general knowledge.
- `_performance/` annotations when qualitative feedback explains a metric change.
- TODO/GitHub tasks only after the review gates show the theme is actionable,
  scoped, privacy-safe, and worker-ready.

## Provenance and Privacy

Every promoted theme preserves internal back-links to source captures, but public
surfaces receive only the minimum safe evidence summary.

- Use capture IDs and redacted excerpt hashes for traceability.
- Do not copy raw correspondence, PII, support tickets, survey exports, or private
  repo names into public issues, PRs, TODO entries, or docs.
- Summarize private evidence as counts and segments, for example: "3 independent
  internal captures from onboarding calls in 2026-Q2".
- Keep sensitive source material in the feedback plane under its retention policy;
  delete or anonymize it when the retention decision says so.
- Promotion records should say what changed, why the evidence met threshold, and
  where the source captures can be rechecked by an authorized reviewer.

## CLI Design

The public surface is `aidevops feedback <command>`. Phase 5 defines the
contract only; command wiring belongs in a follow-up implementation task after
the capture, retention, mining, and promotion contracts are stable.

```bash
# Capture one feedback item into _feedback/captures/
aidevops feedback capture --source <uri-or-label> --channel <channel> --text <text>
aidevops feedback capture --file path/to/note.md --source <uri-or-label> --channel <channel>

# List retained captures and mined themes
aidevops feedback list
aidevops feedback list --state captured|mined|promoted|retired --sensitivity public|internal|client|privileged --since 2026-05-01

# Mine captures into candidate themes with evidence thresholds
aidevops feedback mine
aidevops feedback mine --since 30d --segment <segment> --min-evidence 3 --dry-run

# Promote a reviewed capture or theme into another plane
aidevops feedback promote <feedback-id|theme-id> --to knowledge|campaign|project|case|performance|task --reason <why>

# Retire sensitive, obsolete, duplicate, or consent-expired feedback
aidevops feedback retire <feedback-id|theme-id> --reason <why> [--delete-raw]
```

### `capture`

Creates a normalized capture record under `_feedback/captures/`.

Inputs:

- `--source`: source URI, local label, issue/PR reference, meeting note, survey,
  social thread, support ticket, or operator-provided label.
- `--channel`: `client`, `support`, `survey`, `social`, `sales`, `product`,
  `retrospective`, or repo-local extension value.
- `--text` or `--file`: the raw feedback body. File mode preserves formatting
  and avoids shell-history exposure for sensitive text.
- Optional metadata: `--actor`, `--segment`, `--context`, `--sentiment`,
  `--sensitivity`, `--consent`, `--retain-until`, `--case`, `--project`,
  `--campaign`, `--tags`.

Output:

- Prints the capture ID, path, sensitivity tier, retention state, and next
  recommended action (`review`, `mine`, or `retire`).
- Appends an audit entry to `_feedback/index/audit.log` when an index exists.

### `list`

Shows retained captures and mined themes without exposing raw sensitive text by
default.

Inputs:

- Filters: `--state`, `--channel`, `--sensitivity`, `--segment`, `--tag`,
  `--since`, `--until`, `--promoted-to`, `--retired`, `--json`.
- Raw body display requires an explicit `--show-body` flag and must still redact
  secrets and privileged snippets.

Output:

- Human table: ID, date, channel, segment, sensitivity, state, evidence count,
  promotion target, and age/retention warning.
- JSON mode: stable machine-readable records for routine reports.

### `mine`

Clusters captures into candidate themes and records the evidence behind each
theme. One-off comments remain captures; repeated or high-severity patterns
become mined themes.

Inputs:

- Scope: `--since`, `--until`, `--channel`, `--segment`, `--case`, `--project`,
  `--campaign`, `--tag`.
- Thresholds: `--min-evidence`, `--min-segments`, `--require-review`,
  `--include-sensitive`, `--dry-run`.

Output:

- Creates or updates `_feedback/themes/<theme-id>.md` with summary, evidence
  IDs, confidence, sensitivity roll-up, suggested promotion target, and reviewer
  decision fields.
- Prints counts for captures scanned, new themes, updated themes, rejected
  singletons, and sensitivity holds.
- Dry-run prints the same report without writing theme files.

### `promote`

Moves reviewed feedback or mined themes into the destination plane while keeping
the source evidence traceable.

Inputs:

- `<feedback-id|theme-id>` plus `--to knowledge|campaign|project|case|performance|task`.
- Destination selectors as needed: `--campaign <id>`, `--project <id>`,
  `--case <id>`, `--metric <name>`, `--title <task-title>`.
- `--reason` is required and must explain why the evidence is promotion-worthy.

Output:

- Writes the destination artifact or task draft using the promotion-path contract.
- Updates source state to `promoted`, records destination path or issue number,
  and appends an audit entry.
- Never auto-promotes privileged/client feedback without a review marker or
  cryptographic maintainer approval path defined by the retention policy.

### `retire`

Marks feedback as no longer available for mining or promotion.

Inputs:

- `<feedback-id|theme-id>` plus required `--reason`.
- Reasons: `duplicate`, `obsolete`, `consent-expired`, `sensitive`,
  `client-delete`, `merged`, `low-signal`, or repo-local extension value.
- `--delete-raw` removes or redacts raw body content only when retention policy
  allows deletion; otherwise the command writes a tombstone.

Output:

- Updates state to `retired`, records reason, actor, timestamp, and replacement
  ID when applicable.
- Excludes the item from future `mine` runs unless `--include-retired` is used.

## Routine Design

Recurring jobs live in `TODO.md` under `## Routines`; deterministic scripts are
preferred over agent dispatch when no judgment is needed.

```markdown
- [x] r-feedback-mine Feedback mining report — cluster new captures and surface candidate themes repeat:weekly(mon@09:00) ~5m run:scripts/feedback-helper.sh mine --since 7d --min-evidence 3 --report
- [x] r-feedback-retention Feedback retention audit — flag expired consent, privileged holds, and stale raw captures repeat:weekly(mon@09:30) ~3m run:scripts/feedback-helper.sh retention-audit
- [ ] r-feedback-promotion Feedback promotion review — summarize approved themes awaiting destination decisions repeat:weekly(mon@10:00) ~10m agent:Build+
```

Routine evidence:

- Mining report records captures scanned, themes created/updated, evidence count
  per theme, sensitivity holds, and recommended promotion targets.
- Retention audit records expired retention windows, consent gaps, raw captures
  older than policy, and retirement actions taken.
- Promotion review records themes ready for `_knowledge/`, `_campaigns/`,
  `_projects/`, `_cases/`, `_performance/`, or TODO/GitHub task creation.
- Each tick appends JSONL audit rows to `_feedback/index/audit.log` and prints a
  concise markdown summary suitable for a pulse or routine comment.

## Implementation Boundary

This document is design-only. Do not wire `aidevops feedback` into
`.agents/scripts/aidevops.sh` until the earlier phase contracts are stable:

1. Capture schema and required metadata.
2. Retention and sensitivity policy.
3. Mining workflow and evidence thresholds.
4. Promotion path formats and review gates.

The first implementation task should create a dedicated
`.agents/scripts/feedback-helper.sh` and have `aidevops.sh` delegate to it,
mirroring other plane helpers rather than growing the main CLI file.
