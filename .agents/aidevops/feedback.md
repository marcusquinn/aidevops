# Feedback Plane — Promotion Paths

<!-- AI-CONTEXT-START -->

The `_feedback/` plane is the holding area for raw and mined qualitative signal:
user comments, client feedback, support pain, survey responses, sales objections,
social comments, product notes, and retrospective observations. Raw feedback stays
in `_feedback/` until it has enough provenance, sensitivity classification, and
reviewed interpretation to promote safely into another plane.

For cross-plane routing metadata, use `.agents/configs/data-planes.json` as the
canonical registry once `_feedback/` is registered. This document owns the
promotion policy: when mined feedback becomes durable knowledge, campaign input,
project requirement, case note, performance context, or actionable work.

## Promotion Principles

Promotion is a copy-with-pointer operation, not a move. The destination receives
the minimum necessary summary plus a pointer back to the `_feedback/` capture or
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

## Destination Matrix

| Destination | Promote when | Required evidence carried forward | Notes |
|-------------|--------------|-----------------------------------|-------|
| `_knowledge/insights/` | A repeated theme, validated pattern, or reviewed lesson has durable value beyond one project, case, or campaign. | Theme summary, evidence count, representative redacted quotes, source capture IDs, first/last seen timestamps, confidence, sensitivity tier, reviewer/agent, and link to the mined bundle. | Use for reusable insight, not raw complaints. Keep client/private details in placeholders unless the knowledge plane is private and access-controlled. |
| `_campaigns/active/<id>/research/` | Feedback identifies audience pain, objections, language, positioning gaps, creative reactions, or channel-specific opportunities for a known campaign. | Campaign ID, segment, channel, pain/objection summary, representative redacted quotes, evidence count, consent/publicity status, source capture IDs, and sensitivity tier. | Campaign research should receive phrasing and audience context, not full identities. Competitive or pre-launch material inherits campaign sensitivity. |
| `_projects/<id>/requirements/` | Feedback implies a product, service, or delivery requirement that is actionable for a specific project and has enough evidence or explicit maintainer/client direction. | Requirement statement, affected user/segment, acceptance hint, priority rationale, evidence count or explicit requester, source capture IDs, decision owner, and sensitivity tier. | Requirements are commitments. Promote only after mining review or explicit owner direction; ambiguous ideas remain feedback themes. |
| `_cases/<id>/feedback/` or `_cases/<id>/notes/` | Feedback is case-specific evidence, client instruction, dispute context, compliance signal, or material case note. | Case ID, event timestamp, party/role placeholder, channel, exact or redacted quote, source capture ID, sensitivity/privilege tier, and whether the item is evidence, background, or internal note. | Preserve privilege boundaries. Do not copy privileged case feedback into global knowledge or public tasks. |
| `_performance/` annotations | Feedback explains, qualifies, or challenges a metric movement, experiment result, incident trend, campaign result, or business KPI. | Metric or result ID, observation window, feedback theme, evidence count, segment/channel, source capture IDs, confidence, and sensitivity tier. | Qualitative annotations contextualize numbers; they do not replace measurements. Link to the metric artifact rather than duplicating dashboards. |
| TODO / GitHub task | Mined feedback reveals actionable work: a bug, missing doc, product gap, process gap, follow-up investigation, or automation opportunity with enough context for a worker. | Public-safe title, worker-ready problem statement, sanitized evidence summary, affected files or discovery path when known, verification expectation, source theme ID, and privacy review result. | Public repos must never contain private/client names, local paths, raw quotes, emails, or sensitive evidence. Use placeholders and keep detailed evidence in `_feedback/` or a private plane. |

## Destination-Specific Rules

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
target, object-handle, or choose creative. The promoted item should be framed as
audience research: segment, pain, objection, desired outcome, words used, and
channel context.

Carry forward consent/publicity status. If a quote came from a private client,
store a paraphrase or placeholder in campaign research unless the campaign plane
is private and the client has approved reuse.

### Project requirements: `_projects/<id>/requirements/`

Promote to projects only when feedback is actionable for a specific project.
The destination should receive a requirement or acceptance hint, not a broad
theme. Evidence can be either a mined pattern (for example, `N=7 similar support
comments`) or explicit owner/client direction.

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

<!-- AI-CONTEXT-END -->
