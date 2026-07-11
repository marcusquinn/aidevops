<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18100: Normalize issue dependencies before dispatch eligibility

## Pre-flight

- [x] Memory recall: `dependency normalization dispatch eligibility` → no relevant memories returned.
- [x] Discovery pass: prior dependency fixes reviewed; no matching open issue/PR.
- [x] File refs verified: issue relationship, dependency graph, and reconcile paths exist at HEAD.
- [x] Tier: `tier:thinking` — native relationships, textual fallbacks, and status invariants span multiple modules.
- [x] Seeded draft PR decision recorded: skipped — safest normalization boundary needs design judgment.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** Eight roadmap children explicitly said `Blocked by #...` but were labelled available and presented as dispatchable. Three workers launched before independently rediscovering the blockers.

## What

Guarantee that unresolved issue dependencies are normalized into native relationships and `status:blocked` before any queue scanner or dispatcher can advertise the issue as available.

## Why

False availability wastes workers and can produce out-of-order implementation against missing contracts. The dependency statement already existed; automation failed to convert it into enforceable state.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The solution must reconcile native GitHub relationships, body markers, TODO edges, status labels, and eventual unblocking without creating deadlocks.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Existing relationship paths have several prior edge-case fixes; implementation should select one canonical normalization point after current-code inspection.
- **Status:** not-created
- **Freshness evidence:** Target paths and prior dependency issues reviewed.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check recently merged issue-sync and dependency-graph changes.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-relationships.sh` — materialize textual/TODO dependencies as native issue relationships.
- `EDIT: .agents/scripts/pulse-dep-graph.sh` — fail eligibility closed on positively unresolved dependencies and clear stale blocks only with proof.
- `EDIT: .agents/scripts/pulse-issue-reconcile-normalize.sh` — enforce mutually exclusive blocked/available state before dispatch scans.
- `EDIT: .agents/scripts/pulse-check-queue-scan.py` — report dependency-inconsistent availability separately.
- `NEW/EDIT: .agents/scripts/tests/test-dependency-readiness-normalization.sh` — ordered roadmap fixture and native/text fallback cases.

### Implementation Steps

1. Define precedence: native relationship first, structured marker/TODO edge as repair input, free prose only as bounded compatibility fallback.
2. Normalize relationships and status before queue eligibility is computed.
3. Keep the issue blocked when relationship writes fail; record a retryable reason rather than silently exposing it as available.
4. Automatically unblock only after every declared dependency is positively closed/resolved.
5. Cover parent-task, missing issue, circular/self-reference, closed native relationship, and concurrent runner cases.
6. Ensure queue diagnostics distinguish genuinely available from dependency-inconsistent items.

### Verification

```bash
bash .agents/scripts/tests/test-dependency-readiness-normalization.sh
bash .agents/scripts/tests/test-pulse-dep-graph-parse.sh
bash .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
python3 .agents/scripts/pulse-check-queue-scan.py
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] An issue with any open declared dependency cannot appear in the available queue.
- [ ] Missing native relationships are repaired or held with a retryable blocker.
- [ ] Resolved dependencies unblock automatically without human relabelling.
- [ ] Textual and native evidence cannot create circular/self-match deadlocks.
- [ ] Queue diagnostics expose inconsistent state explicitly.
- [ ] Focused tests and lint pass.

## Recovery Checkpoint

If API or broad-test limits interrupt work, preserve the normalization precedence table, fixtures, and a focused-test-passing WIP commit.
