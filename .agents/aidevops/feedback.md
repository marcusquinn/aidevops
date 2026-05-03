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

## Capture Contract

`_feedback/captures/` is the raw-capture location for retained qualitative
feedback. A capture is evidence, not interpretation: store enough normalized
metadata to re-check provenance, consent, sensitivity, and context before any
agent mines or promotes the signal.

Each capture SHOULD be a markdown file with YAML frontmatter plus the original
quote or privacy-safe summary in the body. Repos may generate sidecar JSON later,
but the markdown contract is the human-readable baseline.

### Required Metadata Fields

| Field | Purpose |
|-------|---------|
| `id` | Stable capture ID, unique within `_feedback/captures/`. |
| `source` | Origin label or pointer: meeting note, issue/PR, survey export, support ticket, social thread, sales note, retrospective, or local file. |
| `timestamp` | When the feedback was observed or captured, preferably ISO 8601 UTC. |
| `actor` / `segment` | Speaker identity when safe, otherwise a privacy-safe role or audience segment such as `trial-user`, `client-admin`, or `internal-maintainer`. |
| `context` | Product, project, campaign, case, feature, workflow, or decision surface the feedback refers to. |
| `channel` | Collection channel such as `client`, `support`, `survey`, `social`, `sales`, `product`, or `retrospective`. |
| `raw_quote` / `summary` | Verbatim quote when retention and consent allow it; otherwise a faithful privacy-safe summary. |
| `sentiment` | `positive`, `negative`, `neutral`, `mixed`, or `unknown`. |
| `sensitivity` | `public`, `internal`, `confidential`, `restricted`, `client`, or `privileged` according to the local sensitivity policy. |
| `consent` | Capture/mining permission such as `explicit`, `implied`, `internal-use`, `anonymized-only`, or `none`. |
| `retention_hint` | Suggested retention action or horizon: `keep`, `review-by:<date>`, `delete-after:<date>`, `anonymize`, or `case-bound`. |
| `provenance` | Pointer that lets an authorized reviewer find the source again: capture import ID, file path, issue/PR reference, case ID, message hash, or redacted excerpt hash. |

`raw_quote` and `summary` are alternatives: one of them is required. Prefer
`summary` when the source contains personal, client, privileged, or private repo
details that must not be copied into versioned docs or public GitHub surfaces.

### Minimal Capture Example

```markdown
---
id: feedback-2026-05-03-001
source: "demo-call-notes:2026-05-03"
timestamp: "2026-05-03T09:30:00Z"
actor: "anonymous trial user"
segment: "solo-founder"
context: "onboarding checklist"
channel: "client"
summary: "The user said the setup checklist was clear but wanted a shorter recovery path after a failed token setup."
sentiment: "mixed"
sensitivity: "internal"
consent: "anonymized-only"
retention_hint: "review-by:2026-08-03"
provenance: "local-note-hash:sha256:example-redacted-hash"
---

Privacy-safe summary only. No personal names, client identifiers, credentials,
private repo names, or raw call transcript are stored in this capture.
```

Capture files MAY add optional routing fields (`case`, `project`, `campaign`,
`tags`, `language`, `import_batch`) when known. Optional fields must not replace
the required provenance, consent, sensitivity, and retention metadata above.

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

## Promotion Principles

Promotion is a copy-with-pointer operation, not a move. The destination receives
the smallest useful summary plus a pointer back to the `_feedback/` capture or
mined theme bundle. The original capture remains governed by `_feedback/`
retention and sensitivity rules unless it is explicitly retired or deleted.

Promote only when all of these are true:

- **Provenance is present:** source, capture timestamp, channel, actor or segment,
  capture method, and original wording or redacted quote are recorded.
- **Sensitivity is classified:** public, internal, confidential, restricted,
  privileged, client-specific, or another repo-defined tier is stamped before any
  public or cross-plane write.
- **Interpretation is separated from evidence:** the promoted summary states what
  was inferred and links to the evidence that supports it.
- **Destination owner is clear:** the receiving plane has an obvious lifecycle for
  the promoted item; otherwise keep the item in `_feedback/` for later review.

## Promotion Paths

Approved mined themes route to the smallest durable surface that can use them.

| Destination | Promote when | Required evidence carried forward | Notes |
|-------------|--------------|-----------------------------------|-------|
| `_knowledge/insights/` | A repeated theme, validated pattern, or reviewed lesson has durable value beyond one project, case, or campaign. | Theme summary, evidence count, representative redacted quotes, source capture IDs, first/last seen timestamps, confidence, sensitivity tier, reviewer/agent, and link to the mined bundle. | Use for reusable insight, not raw complaints. Keep client/private details as placeholders unless the knowledge plane is private and access-controlled. |
| `_campaigns/active/<id>/research/` | Feedback identifies audience pain, objections, language, positioning gaps, creative reactions, or channel-specific opportunities for a known campaign. | Campaign ID, segment, channel, pain/objection summary, representative redacted quotes, evidence count, consent/publicity status, source capture IDs, and sensitivity tier. | Campaign research receives phrasing and audience context, not full identities. Competitive or pre-launch material inherits campaign sensitivity. |
| `_projects/<id>/requirements/` | Feedback implies a product, service, or delivery requirement that is actionable for a specific project and has enough evidence or explicit maintainer/client direction. | Requirement statement, affected user/segment, acceptance hint, priority rationale, evidence count or explicit requester, source capture IDs, decision owner, and sensitivity tier. | Requirements are commitments. Promote only after mining review or explicit owner direction; ambiguous ideas remain feedback themes. |
| `_cases/<id>/feedback/` or `_cases/<id>/notes/` | Feedback is case-specific evidence, client instruction, dispute context, compliance signal, or material case note. | Case ID, event timestamp, party/role placeholder, channel, exact or redacted quote, source capture ID, sensitivity/privilege tier, and whether the item is evidence, background, or internal note. | Preserve privilege boundaries. Do not copy privileged case feedback into global knowledge or public tasks. |
| `_performance/` annotations | Feedback explains, qualifies, or challenges a metric movement, experiment result, incident trend, campaign result, or business KPI. | Metric or result ID, observation window, feedback theme, evidence count, segment/channel, source capture IDs, confidence, and sensitivity tier. | Qualitative annotations contextualize numbers; they do not replace measurements. Link to the metric artifact rather than duplicating dashboards. |
| TODO / GitHub task | Mined feedback reveals actionable work: a bug, missing doc, product gap, process gap, follow-up investigation, or automation opportunity with enough context for a worker. | Public-safe title, worker-ready problem statement, sanitized evidence summary, affected files or discovery path when known, verification expectation, source theme ID, and privacy review result. | Public repos must never contain private/client names, local paths, raw quotes, emails, or sensitive evidence. Use placeholders and keep detailed evidence in `_feedback/` or a private plane. |

### Durable insights: `_knowledge/insights/`

Promote to knowledge when the feedback is useful outside the immediate workflow.
Typical triggers are repeated pain across captures, a validated customer segment
pattern, a reusable lesson from support or delivery, or a campaign/project
post-mortem learning supported by feedback.

Carry forward:

- source capture IDs or theme bundle ID;
- evidence count and representative redacted quotes;
- who/what reviewed the mining result;
- confidence and what would falsify the insight;
- sensitivity tier and any access caveat.

Do not promote a single unreviewed comment as knowledge unless it is explicitly a
decision record or authoritative user instruction.

### Campaign research: `_campaigns/active/<id>/research/`

Promote to campaigns when the feedback changes how a campaign should speak,
target, handle objections, or choose creative. The promoted item should be
framed as audience research: segment, pain, objection, desired outcome, words
used, and channel context.

Carry forward consent/publicity status. If a quote came from a private client,
store a paraphrase or placeholder in campaign research unless the campaign plane
is private and the client has approved reuse.

### Project requirements: `_projects/<id>/requirements/`

Promote to projects only when feedback is actionable for a specific project. The
destination should receive a requirement or acceptance hint, not a broad theme.
Evidence can be either a mined pattern, such as `N=7 similar support comments`,
or explicit owner/client direction.

If the project is not yet known, keep the item as a feedback theme and create a
task only for discovery if the next step is clear.

### Case notes: `_cases/<id>/feedback/` or `_cases/<id>/notes/`

Promote to cases when the signal is part of a matter record. Preserve the
original timestamp, channel, party role, and privilege/sensitivity tier. Case
promotion is usually more sensitive than knowledge or campaign promotion; never
copy case-specific details into global planes without explicit redaction and a
reason.

Use placeholders such as `<client>`, `<opposing-party>`, or `<matter>` when any
public artifact refers to a case-derived task.

### Performance annotations: `_performance/`

Promote to performance when qualitative feedback explains quantitative movement:
a conversion drop, support spike, churn reason, campaign result, release outcome,
or incident trend. The annotation must name the metric/result window and link to
the feedback bundle that supports the explanation.

Do not present feedback as measurement. Label promoted content as qualitative
context with confidence and evidence count.

### TODO / GitHub tasks

Create tasks from feedback when there is a concrete worker-ready action. A task
must include a public-safe problem statement, expected outcome, likely files or
discovery path, and verification. If the evidence is private, the issue should
say "reported from private feedback" or "observed in a managed private repo" and
link only to a private/local source that public readers cannot infer.

Public GitHub task rules:

- never include private repo names, client names, personal data, email addresses,
  local paths, screenshots, or raw sensitive quotes;
- replace identifiers with placeholders (`<client>`, `<user-segment>`,
  `<private-repo>`, `<case-id>`);
- include enough generalized context for implementation without exposing source
  material;
- keep detailed evidence in `_feedback/` or the relevant private plane;
- if redaction would remove the implementation context, create the task in a
  private repo or keep it as `_feedback/` until a maintainer can route it.

## No-Promote and Retire Outcomes

Not every capture should leave `_feedback/`.

Keep feedback in `_feedback/` only when:

- it is a single weak signal with no clear destination;
- source, timestamp, actor/segment, or sensitivity classification is missing;
- the destination plane is unknown or would duplicate another lifecycle;
- privacy redaction would remove too much context for safe use;
- the item needs more mining, deduplication, or human review.

Retire feedback when:

- the capture is duplicate evidence already represented by a retained theme;
- retention policy expires or consent is withdrawn;
- the feedback is superseded by later evidence and no longer useful;
- the capture was spam, malformed, non-actionable, or outside the repo's scope;
- the promoted destination now carries the durable summary and the raw capture is
  no longer needed under retention policy.

Retirement should record the reason, timestamp, actor/agent, and any destination
that received a promoted summary. Deletion is reserved for retention, consent,
legal, or security requirements and should leave only an audit-safe tombstone
when policy allows.

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
