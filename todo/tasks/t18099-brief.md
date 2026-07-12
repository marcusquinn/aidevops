<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18099: Make dispatch claim-to-worker handoff an atomic expiring lease

## Pre-flight

- [x] Memory recall: `dispatch lease claim-only machine heartbeat` → no relevant memories returned.
- [x] Discovery pass: no matching open issue/PR; current claim, ledger, worker lifecycle, and stale-dispatch tests verified.
- [x] File refs verified: dispatch claim/ledger and worker lifecycle paths exist at HEAD.
- [x] Tier: `tier:thinking` — cross-machine concurrency and failure recovery require protocol design.
- [x] Seeded draft PR decision recorded: skipped — protocol changes need test-driven design.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** Several issues remained assigned and `status:queued` after only a claim comment was posted, while no worker existed. GitHub usernames could not distinguish separate machines using the same account.

## What

Replace the claim/assignment/start gap with an atomic, expiring dispatch lease that records machine identity and transitions to active ownership only after worker readiness is proven.

## Why

Claim-only assignments can suppress all other runners for hours. Human inspection should not be required to determine whether a remote worker exists or whether takeover is safe.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires a backward-compatible cross-runner lease protocol, machine identity, readiness acknowledgment, takeover rules, and race tests.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The durable source of truth and transition ordering require design judgment.
- **Status:** not-created
- **Freshness evidence:** Current dispatch claim, ledger, lifecycle, and stale-recovery paths inspected.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check any task-coordinator work merged after filing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/dispatch-claim-helper.sh` — issue a bounded pre-launch lease and deterministic takeover markers.
- `EDIT: .agents/scripts/dispatch-ledger-helper.sh` — persist runner device, session, lease phase, expiry, and readiness evidence.
- `EDIT: .agents/scripts/worker-lifecycle-common.sh` — acknowledge readiness and emit terminal lease evidence.
- `EDIT: .agents/scripts/dispatch-dedup-stale.sh` — reverify expired assumptions before takeover.
- `NEW/EDIT: .agents/scripts/tests/test-dispatch-atomic-lease.sh` — concurrent runners, same-login devices, launch crash, readiness, expiry, and takeover.

### Implementation Steps

1. Define lease phases: pre-launch, ready/active, terminal/released, each with explicit expiry semantics.
2. Add a stable non-secret machine/device identifier distinct from GitHub login.
3. Delay durable assignment/queued ownership until readiness, or make pre-launch state automatically reclaimable after a short grace period.
4. On expiry, recheck process/PR/branch/timeline evidence before takeover; never infer completion from process exit.
5. Preserve interoperability with older runners and fail closed only for the unsafe action, not the objective.
6. Add multi-process and same-user/different-device fixtures.
7. Create a focused-test-passing WIP commit before broad gates.

### Verification

```bash
bash .agents/scripts/tests/test-dispatch-atomic-lease.sh
bash .agents/scripts/tests/test-dispatch-claim-helper.sh
bash .agents/scripts/tests/test-dispatch-dedup-stale-no-worker.sh
bash .agents/scripts/tests/test-dispatch-ledger-helper.sh
shellcheck .agents/scripts/dispatch-claim-helper.sh .agents/scripts/dispatch-ledger-helper.sh .agents/scripts/worker-lifecycle-common.sh .agents/scripts/dispatch-dedup-stale.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Claim-only launch failures self-release without waiting for human discovery.
- [ ] Same-login machines are distinguishable in lease and recovery evidence.
- [ ] Active remote workers remain protected from duplicate dispatch.
- [ ] Expired leases trigger evidence-based takeover or a scheduled retry, never silent abandonment.
- [ ] Legacy runner markers remain readable during rollout.
- [ ] Focused concurrency tests and lint pass.

## Recovery Checkpoint

If interrupted, push protocol fixtures and the documented transition table before broad integration so later workers can resume without guessing lease semantics.
