<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18104: Automate failure-family remediation and human-gate revalidation

## Pre-flight

- [x] Memory recall: `failure family remediation human gate revalidation` → no relevant memories returned.
- [x] Discovery pass: pulse-check diagnostics and NMR automation tests reviewed; no matching open issue/PR.
- [x] File refs verified: pulse-check, worker activity, current state, and NMR paths exist at HEAD.
- [x] Tier: `tier:thinking` — combines evidence thresholds, deduplicated issue generation, and authority-safe gate revalidation.
- [x] Seeded draft PR decision recorded: skipped — thresholds and NMR reason schema require design judgment.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** Worker success was 65% with repeated stall/local-runtime families, while some NMR and blocked states risked becoming passive human queues even when automation could diagnose or repair them.

## What

Continuously cluster worker/pulse failure families into deduplicated worker-ready remediation tasks and periodically revalidate human gates so only genuine authority decisions remain assigned to people.

## Why

Repeated infrastructure failures should improve the system rather than recur indefinitely. Humans should be interrupted only for consequential authority, secrets, destructive actions, billing, or irreducible decisions—not missing diagnostics or automation gaps.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires reliable evidence thresholds, privacy-safe issue generation, reason-coded NMR semantics, and cryptographic-gate preservation.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The worker must derive thresholds from current metrics and preserve existing trust boundaries.
- **Status:** not-created
- **Freshness evidence:** Current diagnostics and NMR files/tests verified at HEAD.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check current failure distribution and any new pulse-check autofile findings.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/worker-activity-helper.sh` — emit stable failure-family fingerprints and recovery outcomes.
- `EDIT: .agents/scripts/pulse-check-helper.sh` — threshold, deduplicate, and file worker-ready infrastructure remediation issues.
- `EDIT: .agents/scripts/pulse-nmr-approval.sh` — require reason-coded human authority and schedule revalidation of temporary assumptions.
- `EDIT: .agents/scripts/pulse-current-state-helper.sh` — expose NMR age/reason and failure-family remediation status.
- `NEW/EDIT: .agents/scripts/tests/test-failure-family-remediation.sh` — recurrence, dedup, privacy, recovery closure, and NMR revalidation.

### Implementation Steps

1. Define stable privacy-safe fingerprints for watchdog stalls, local runtime errors, launch failures, rate limits, and recovery failures.
2. File one worker-ready task only when recurrence/confidence thresholds pass; update existing evidence instead of comment-storming.
3. Track whether the remediation task reduced or eliminated the family and close/supersede it only with outcome evidence.
4. Add structured NMR reasons separating authority/secret/destructive/billing decisions from transient infrastructure, missing context, or diagnostic ambiguity.
5. Periodically reverify temporary NMR assumptions; automatically return automatable cases to diagnostic or implementation workers without bypassing cryptographic approvals.
6. Preserve human gates for genuine authority and emit a concise decision packet with options/evidence.
7. Add API-budget, rate-limit, and privacy guards.

### Verification

```bash
bash .agents/scripts/tests/test-failure-family-remediation.sh
bash .agents/scripts/tests/test-pulse-check-helper.sh
bash .agents/scripts/tests/test-worker-activity-helper.sh
bash .agents/scripts/tests/test-pulse-nmr-approval.sh
bash .agents/scripts/tests/test-pulse-nmr-maintainer-authority.sh
shellcheck .agents/scripts/worker-activity-helper.sh .agents/scripts/pulse-check-helper.sh .agents/scripts/pulse-nmr-approval.sh .agents/scripts/pulse-current-state-helper.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Recurrent high-confidence failure families create one deduplicated worker-ready remediation issue.
- [ ] Remediation outcome is measured before the family is considered solved.
- [ ] NMR states carry a structured genuine-authority reason or are automatically re-evaluated.
- [ ] Cryptographic approval and trust boundaries cannot be bypassed by automation.
- [ ] Humans receive decision-ready packets only for irreducible authority blockers.
- [ ] Public issues contain aggregate/privacy-safe evidence only.
- [ ] Focused tests and lint pass.

## Recovery Checkpoint

Before broad gates, push fingerprint/NMR fixtures and a focused-test-passing WIP; record chosen thresholds and any unresolved privacy constraints.
