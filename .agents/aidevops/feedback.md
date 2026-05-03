# Feedback Plane — Mining Workflow

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

The `_feedback/` plane stores qualitative signal that is not yet durable
knowledge, a project requirement, campaign research, or a task. Mining is the
reviewed workflow that turns repeated, severe, or explicitly requested feedback
into promoted outputs while keeping isolated or sensitive comments as contextual
evidence only.

For shared plane metadata, use `.agents/configs/data-planes.json` when a registry
entry exists. This document owns the mining policy for `_feedback/`; capture and
retention details stay with the feedback capture and sensitivity contracts.

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
   and any contradicting/neutral feedback.
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
