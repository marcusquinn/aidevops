---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18442: Repin recovered release snapshot after authorization expansion

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `release lane repin recovered snapshot after authorization expansion` → 0 hits — no relevant lessons
- [x] Discovery pass: 12 recent commits / 0 additional merged related PRs / 0 open related PRs found for the target files
- [x] File refs verified: 4 refs checked, all present at HEAD `6552444961c04093333bada737af2868c48f4609`
- [x] Tier: `tier:thinking` — immutable release snapshot mutation is a critical publication trust boundary
- [x] Seeded draft PR decision recorded: skipped — interactive repair will be verified before PR creation

## Origin

- **Created:** 2026-09-16
- **Session:** OpenCode:current-interactive
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** The t18441 retry correctly expanded persisted authorization from two to eight reviewed sources, then release preparation reused the failed attempt's old snapshot SHA. Provenance capture refused because later authorized merges are not ancestors of that old snapshot.

## What

Atomically and recoverably repin a reopened tagless lane from its failed snapshot to the exact newer resolver-reviewed snapshot after authorization expansion. Preserve the original release base/tag/object, require the old snapshot to match failure evidence, and refuse unrelated lane, manifest, owner, base, or snapshot drift.

## Why

The authorized minor incremental release for PR #31958 remains blocked pre-tag. Runtime evidence shows authorization expansion succeeded, but `_full_loop_release_prepare_new` detached at the original PR #31958 merge and provenance capture rejected PR #31960 as a non-ancestor.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Trust invariants are supplied; transactional details require review.
- [x] **Targets and reference pattern verified?** Lane CAS and recovery call sites are identified.
- [ ] **No semantic or design decision remains?** Safe recovered-snapshot repinning requires trust-boundary reasoning.
- [ ] **Bounded, reversible, low-consequence impact?** Release publication state is critical.
- [x] **No stateful coordination to invent?** Existing operation-token and compare-and-swap lane writes are reused.
- [x] **Focused verification and rollback are explicit?** Two focused suites, ShellCheck, and changed-file lint are specified.
- [x] **No dispatch-path risk override?** No worker dispatch path changes.

**Selected tier:** `tier:thinking`

**Tier rationale:** This is a bounded correction to an existing fenced transaction, but it changes immutable snapshot state used by publication.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Runtime reproduction and exact files are known; create the PR after focused verification.
- **Status:** `not-created`
- **Freshness evidence:** reproduced at current main with lane phase `reserved`, eight-source authorization, and old snapshot `3be82399...`
- **Verification run:** no implementation checks yet
- **Stale-assumption warning:** Revalidate lane, resolver snapshot, and absent publication channels before retry.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/release-lane-helper.sh:1199-1250` — add a fenced CAS helper that repins only a recovered tagless snapshot.
- `EDIT: .agents/scripts/full-loop-release-aggregate-recovery.sh:1052-1129` — invoke repinning after verified recovery/authorization convergence, including crash-resume paths.
- `EDIT: .agents/scripts/tests/test-release-snapshot-helper.sh:184-210` — prove allowed repin and reject owner/base/evidence/manifest drift.
- `EDIT: .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh:1085-1382` — prove snapshot recovery invokes repinning before release preparation.

### Complete Write Surface

- **Callers/readers:** `_full_loop_recovery_expand_reserved_authorization` prepares the exact resolver snapshot before invoking the lane helper; `_full_loop_release_prepare_new` consumes `snapshot_sha`.
- **Writers/mutation paths:** `_release_lane_write` remains the sole lane CAS writer.
- **Existing verification/tests:** aggregate recovery and release snapshot focused suites.
- **Schemas/config:** No schema version change; existing `prepublication_recovery` and snapshot fields are reused.
- **Generated/deployed mirrors:** Deploy with `setup.sh --non-interactive` only after merge, before release retry.
- **Migrations/backfills:** Existing affected lanes are repaired idempotently on retry.
- **Cleanup/rollback paths:** CAS failure leaves the lane fenced; reverting restores refusal without altering published state.

### Implementation Steps

1. Add a lane helper requiring active reserved ownership, null tag/receipt, exact expected sources, matching pre-publication marker, old snapshot equal to failed-source merge, unchanged snapshot base metadata, and either old or already-repinned snapshot.
2. Update only `snapshot_sha` plus manifest-bound metadata and timestamp using the existing lane CAS writer; verify the exact resulting state after ambiguous writes.
3. In snapshot-mode failed-prepublication recovery, derive the new snapshot/base from the already validated resolver result and call the helper after authorization converges, including same-manifest crash retries.
4. Add positive, idempotent, mismatch, and stale-owner tests; rerun the observed release path only after merge and deployment.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing operation token and expected lane-head compare-and-swap must fence every mutation.
- **Migration/rollback:** No schema migration; old lanes repair only after all new checks pass.
- **Mixed-version/backward compatibility:** Direct and aggregate recovery modes must not repin; normal immutable snapshot pinning remains unchanged.
- **Idempotency/retry:** Repeating the exact repin succeeds; any changed snapshot/base/manifest/evidence refuses.
- **Partial failure/recovery:** A crash before repin is resumed; a crash after the CAS observes the exact already-repinned state.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
bash .agents/scripts/tests/test-release-snapshot-helper.sh
shellcheck .agents/scripts/full-loop-release-aggregate-recovery.sh .agents/scripts/release-lane-helper.sh .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh .agents/scripts/tests/test-release-snapshot-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Focused suites prove transaction behavior and release consumption; ShellCheck and changed-file lint cover shell and repository contracts.
- **Broad verification trigger:** Release infrastructure is shared, but existing focused suites plus required CI are the narrowest applicable proof; full local lint is not required unless changed-file gates identify broader impact.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: both focused release suites
- [ ] WIP commit created before broad gates: `wip: repin recovered release snapshots`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Release PR #31958 as a minor incremental release through the retained provenance-bound lane.
- **Preserved user directions:** Minor and incremental only; no manual state edit, override, force-push, manual tag, or independent bump.
- **Trigger and evidence:** Authorization expansion succeeded, then provenance capture rejected later sources against old snapshot `3be82399...`.
- **Completed and verified:** t18441 merged; eight-source snapshot resolver output is exact; no tag or publication exists.
- **Remaining acceptance criteria:** Merge/deploy repin fix, retry, and verify terminal publication/deployment evidence.
- **Unsafe route not to repeat:** Reusing the old snapshot after expanding its manifest.
- **Next safe route:** Fenced CAS repin from validated resolver state.
- **Resume condition:** Fix merged/deployed, lane remains tagless, channels absent.
- **Owner and status:** AI DevOps interactive session; recovering.

### Files Scope

- `.agents/scripts/full-loop-release-aggregate-recovery.sh`
- `.agents/scripts/release-lane-helper.sh`
- `.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh`
- `.agents/scripts/tests/test-release-snapshot-helper.sh`
- `TODO.md`
- `todo/tasks/t18442-brief.md`

## Acceptance Criteria

- [ ] A verified expanded pre-publication lane repins from the failed source snapshot to the exact resolver-reviewed snapshot before preparation.
- [ ] Same-state retry is idempotent and direct/aggregate recovery behavior is unchanged.
- [ ] Stale owner, wrong base, wrong old snapshot/evidence, manifest mismatch, published/tagged lane, or alternate new snapshot is rejected.
- [ ] Focused suites, ShellCheck, changed-file lint, required CI, and independent critical review pass.
- [ ] The retained PR #31958 release progresses beyond authorization capture without manual state edits.

## Context & Decisions

- Preserve the release base/tag/object because both old and new snapshots descend from the same latest published base.
- Repin only while tagless and reserved with the persisted recovery marker.
- Keep normal immutable snapshot pinning strict; this is an explicit recovered-prepublication transition.

## Relevant Files

- `.agents/scripts/full-loop-release-helper.sh:296-368` — consumer that detached at stale lane snapshot.
- `.agents/scripts/full-loop-release-aggregate-recovery.sh:1052-1129` — verified recovery/authorization transaction.
- `.agents/scripts/release-lane-helper.sh:833-1055,1199-1250` — lane recovery, CAS, and immutable snapshot guards.

## Dependencies

- **Blocked by:** none
- **Blocks:** Minor incremental release for PR #31958.
- **External:** GitHub reads and release channels during final retry.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Observed trace and lane contracts |
| Implementation | 45m | CAS helper and recovery integration |
| Verification | 55m | Focused suites, lint, review, PR gates |
| **Total** | **~2h** | |
