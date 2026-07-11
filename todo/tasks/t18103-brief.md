<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18103: Reconcile stale objectives with expiring assumptions and durable recovery

## Pre-flight

- [x] Memory recall: `stale objective assumption expiry recovery` → no relevant memories returned.
- [x] Discovery pass: existing stale dispatch and current-state helpers reviewed; no matching open issue/PR.
- [x] File refs verified: pulse reconcile, current-state, lifecycle, and stale-dispatch tests exist at HEAD.
- [x] Tier: `tier:thinking` — introduces a cross-state objective invariant and recovery controller.
- [x] Seeded draft PR decision recorded: skipped — state model must be designed from current evidence sources.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** GitHub states repeatedly implied workers or blockers existed when current evidence contradicted them. Recovery depended on a human correlating process, PR, branch, comments, labels, and worktrees.

## What

Add a deterministic objective reconciliation controller that guarantees every open actionable objective has a verified state, bounded assumption, durable next action, and scheduled recovery until completion, cancellation, or demonstrated impossibility.

## Why

Failing closed on one unsafe action must not strand the objective. Dashboards should audit autonomous recovery, not be the primary mechanism by which neglected work is discovered.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires a new state model across issues, workers, PRs, branches, worktrees, dependencies, and recovery evidence.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A speculative implementation would prematurely choose evidence precedence and recovery semantics.
- **Status:** not-created
- **Freshness evidence:** Existing reconcile/current-state/lifecycle paths verified at HEAD.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Coordinate with any task-coordinator or lease protocol merged after filing.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/objective-reconciliation-helper.sh` — derive objective state, expiring assumptions, and next actions from durable evidence.
- `EDIT: .agents/scripts/pulse-issue-reconcile.sh` — invoke bounded reconciliation and apply idempotent repairs.
- `EDIT: .agents/scripts/pulse-current-state-helper.sh` — expose objectives without next actions and oldest unverified assumptions.
- `EDIT: .agents/scripts/worker-lifecycle-common.sh` — emit the minimum terminal/recovery evidence required by reconciliation.
- `NEW: .agents/scripts/tests/test-objective-reconciliation.sh` — exhaustive state-transition fixtures.

### Implementation Steps

1. Define objective states separately from execution-path states: actionable, actively owned, under review, dependency-blocked, authority-blocked, completed, cancelled, impossible.
2. Require each nonterminal objective to carry evidence timestamp, assumption expiry, next action, trigger/retry time, and responsible automation component.
3. Reconcile queued issues without leases, leases without processes, review states without PRs, failing PRs without repair, resolved blockers, merged PR/open issue drift, and recovery comments without subsequent action.
4. Apply a bounded recovery ladder: retry infrastructure, resume worktree/session, recover branch, repair PR, narrow redispatch, model escalation, diagnostic worker, then decision-ready human packet only for true authority blockers.
5. Preserve commits/logs/verification before cleanup or takeover.
6. Ensure each repair is idempotent and API-budget bounded.
7. Add a WIP checkpoint after fixtures pass before live integration tests.

### Verification

```bash
bash .agents/scripts/tests/test-objective-reconciliation.sh
bash .agents/scripts/tests/test-dispatch-dedup-stale-no-worker.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
bash .agents/scripts/tests/test-pulse-current-state-helper.sh
shellcheck .agents/scripts/objective-reconciliation-helper.sh .agents/scripts/pulse-issue-reconcile.sh .agents/scripts/pulse-current-state-helper.sh .agents/scripts/worker-lifecycle-common.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Every open actionable objective has a machine-readable next action and retry/trigger.
- [ ] Assumptions about workers, PRs, dependencies, and human need expire and are reverified.
- [ ] Safety stops pause only unsafe paths while preserving objective recovery.
- [ ] Recovery preserves task artifacts before cleanup or takeover.
- [ ] Repeated reconciliation is idempotent and bounded.
- [ ] Current-state diagnostics show zero unattended actionable objectives when healthy.
- [ ] Focused tests and lint pass.

## Recovery Checkpoint

Push the state table, fixtures, and focused-test-passing WIP before wiring live writes; record unresolved evidence-precedence decisions explicitly.
