<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18101: Repair terminal CI failures in place on existing PR branches

## Pre-flight

- [x] Memory recall: `terminal CI repair existing PR` → no relevant memories returned.
- [x] Discovery pass: prior CI-routing fix #26045 and current merge feedback paths reviewed; no matching open issue/PR.
- [x] File refs verified: merge process/feedback and CI repair tests exist at HEAD.
- [x] Tier: `tier:thinking` — repair routing, trust gates, branch ownership, and dedup require coordinated changes.
- [x] Seeded draft PR decision recorded: skipped — current failure path must be reproduced before selecting the repair handoff.

## Origin

- **Created:** 2026-07-11
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** An approved worker PR had terminal required Lint/Typecheck failures for about an hour, but no CI repair feedback or repair worker was routed. The issue was incorrectly available, inviting duplicate implementation workers.

## What

Route terminal required-check failures to a bounded worker that repairs the existing trusted PR branch, preserving reviews, discussion, and branch context through successful verification and merge.

## Why

Recreating or redispatching the original issue loses context and generates duplicate PRs. Pending checks must remain pending, while terminal failures need immediate autonomous ownership.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires exact failure-state classification, trust checks, branch-scoped dispatch, deduplication, and fallback behavior.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The existing repair machinery should be repaired rather than bypassed with a speculative seed.
- **Status:** not-created
- **Freshness evidence:** Existing merge repair code and tests verified; live incident supplied terminal required-check evidence.
- **Verification run:** UNVERIFIED — issue composition only.
- **Stale-assumption warning:** Re-check whether a newer pulse release already routed in-place repairs for interactive-origin worker PRs.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-process.sh` — classify latest-head required checks and invoke repair exactly once per failing SHA.
- `EDIT: .agents/scripts/pulse-merge-feedback.sh` — create an in-place PR repair handoff before issue-level close/redispatch fallback.
- `EDIT: .agents/scripts/worker-lifecycle-common.sh` — support PR-branch-scoped repair sessions and terminal evidence.
- `EDIT: .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh` — interactive/worker origins, latest SHA, pending vs terminal, dedup, and fallback.

### Implementation Steps

1. Reproduce a trusted approved PR with terminal required failures and no active repair action.
2. Treat queued/in-progress checks as pending; route only latest-head terminal failures.
3. Dispatch a bounded worker against the existing PR branch with failed check names/log evidence and verification commands.
4. Deduplicate by repository, PR, head SHA, and failure fingerprint.
5. Preserve external-contributor, NMR, workflow-file, and permission trust gates.
6. Fall back to issue-level routing only when branch repair is impossible, with durable reason and retry path.
7. Verify successful repair updates the same PR and returns to normal merge processing.

### Verification

```bash
bash .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh
bash .agents/scripts/tests/test-pulse-merge-required-checks-filter.sh
bash .agents/scripts/tests/test-pulse-merge-fix-worker-dispatch.sh
bash .agents/scripts/tests/test-pulse-merge-phantom-pending-checks.sh
shellcheck .agents/scripts/pulse-merge-process.sh .agents/scripts/pulse-merge-feedback.sh .agents/scripts/worker-lifecycle-common.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Latest-head terminal required failures receive one in-place repair worker.
- [ ] Pending checks never trigger duplicate repair.
- [ ] Reviews, branch, and PR discussion are preserved through repair.
- [ ] Trust/NMR/external-contributor gates remain fail closed.
- [ ] Impossible branch repairs fall back with a durable scheduled next action.
- [ ] Focused tests and lint pass.

## Recovery Checkpoint

Push failure-state fixtures and a WIP commit after focused routing tests pass; record any unverified provider/GitHub behavior separately.
