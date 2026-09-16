---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18441: Allow snapshot release retries to expand verified authorization

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `snapshot release retry authorization expansion` → 0 hits — no relevant lessons
- [x] Discovery pass: 5 commits / 1 merged PR / 0 known open PRs touch the target files in the inspected history; prior fix is GH#31897 / PR #31901
- [x] File refs verified: 2 refs checked, all present at HEAD `42b453d7001dad11d5c2ee7a3d97208eb6ace8b4`
- [x] Tier: `tier:thinking` — release authorization is a critical trust boundary even though the observed failure and candidate invariant are bounded
- [x] Seeded draft PR decision recorded: skipped — implement and verify interactively before creating the PR

## Origin

- **Created:** 2026-09-16
- **Session:** OpenCode:current-interactive
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** A retained tagless release lane for PR #31958 was authorized with an immutable two-source manifest. After reviewed fixes advanced `main`, the exact current snapshot contains six sources; the retry validator rejects it because it requires the failed source identity to equal the current snapshot tip.

## What

Allow a failed pre-publication snapshot retry to use a newer, resolver-verified complete snapshot when the persisted immutable authorization is a strict subset of that snapshot. The validator must still bind the failed source to persisted authorization, bind the current snapshot tip to the resolver output, and reject malformed, incomplete, conflicting, or unreviewed manifests before any lane mutation or publication.

## Why

The explicitly authorized minor incremental release for source PR #31958 is blocked before tag creation even though every additional source was merged and the caller supplied the resolver's complete immutable snapshot. Without this correction, any pre-tag failure followed by an intervening reviewed merge can strand a fenced release lane permanently.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** The invariants are specified, but implementation details require trust-boundary review.
- [x] **Targets and reference pattern verified?** The validator and focused test block are identified.
- [ ] **No semantic or design decision remains?** Safe authorization expansion semantics must be reviewed against existing release invariants.
- [ ] **Bounded, reversible, low-consequence impact?** This changes a release authorization trust boundary.
- [x] **No stateful coordination to invent?** Existing fenced lane and authorization-refresh mechanisms remain unchanged.
- [x] **Focused verification and rollback are explicit?** Focused tests, ShellCheck, and changed-file lint are specified; rollback is the isolated commit.
- [x] **No dispatch-path risk override?** No worker dispatch path is modified.

**Selected tier:** `tier:thinking`

**Tier rationale:** The write surface is narrow, but snapshot authorization controls publication provenance and therefore requires explicit fail-closed reasoning and negative regression coverage.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The interactive owner has an isolated worktree and will create a PR only after the trust-boundary behavior passes focused checks.
- **Status:** `not-created`
- **Freshness evidence:** inspected current HEAD, persisted lane evidence, resolver output, prior PR #31901, and focused tests
- **Verification run:** pre-edit and duplicate discovery passed; implementation checks not yet run
- **Stale-assumption warning:** Re-evaluate if `main`, the retained lane, or publication channels change before release retry.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-release-aggregate-recovery.sh:361-415` — replace snapshot-tip equality with explicit complete-snapshot and persisted-subset invariants.
- `EDIT: .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh:984-1032` — cover safe expansion and rejection of missing, extra, duplicate, malformed, conflicting, or unbound entries.

### Complete Write Surface

- **Callers/readers:** `_full_loop_recovery_validate_failed_prepublication_intent` is the sole caller of `_full_loop_recovery_validate_snapshot_prepublication_record`; `_full_loop_recovery_prepare_prepublication_source` populates the reviewed resolver state.
- **Writers/mutation paths:** No state writer changes. Validation occurs before `_full_loop_recovery_expand_reserved_authorization` mutates the fenced lane.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh` directly exercises direct, aggregate, snapshot, and authorization-refresh behavior.
- **Schemas/config:** Persisted lane and failure-evidence schemas remain unchanged.
- **Generated/deployed mirrors:** No generated mirror is edited; `setup.sh --non-interactive` is unnecessary before merge because source scripts are exercised directly.
- **Migrations/backfills:** None; existing tagless lanes become retryable only after all new invariants pass.
- **Cleanup/rollback paths:** Revert the isolated implementation commit; no lane or publication state is changed by the fix PR itself.

### Implementation Steps

1. Validate that resolver JSON source identity still matches `_FULL_LOOP_RESOLVED_SOURCE_PR` and `_FULL_LOOP_RESOLVED_SOURCE_MERGE` and appears exactly once in the complete snapshot manifest.
2. Validate that the recorded failed source appears exactly once in the snapshot and remains present in the persisted authorization.
3. Require the resolver-derived snapshot manifest to exactly match `_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED`, while requiring the persisted authorization only to be a subset of that complete snapshot.
4. Extend focused tests with a failed source at an earlier snapshot plus a newer reviewed snapshot tip, and retain negative coverage for missing, extra, duplicate, malformed, SHA-conflicting, or unbound data.
5. Run the focused recovery test, ShellCheck for both changed shell files, and `.agents/scripts/linters-local.sh --changed`.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing fenced authorization-refresh transactions remain responsible for mutation; the validator only admits or refuses before that transaction.
- **Migration/rollback:** No schema migration. Reverting restores exact-snapshot-only behavior.
- **Mixed-version/backward compatibility:** Exact snapshot retries, direct retries, and aggregate retries must continue to pass unchanged.
- **Idempotency/retry:** A repeated retry with the same complete reviewed snapshot and persisted subset must make the same decision.
- **Partial failure/recovery:** Any validation ambiguity must refuse before tag creation or authorization mutation and retain the existing evidence.

### Verification Before Dispatch

```bash
.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
shellcheck .agents/scripts/full-loop-release-aggregate-recovery.sh .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused suite proves positive expansion and negative provenance cases; ShellCheck covers shell correctness; changed-file lint enforces repository gates and complexity ratchets.
- **Broad verification trigger:** Not required unless changed-file lint identifies a shared release-contract dependency requiring a broader suite.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh`
- [ ] WIP commit created before broad gates: `wip: allow verified snapshot authorization expansion`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Release PR #31958 as a minor incremental release through the retained provenance-bound lane.
- **Preserved user directions:** Minor and incremental only; no override, manual tag, manual state edit, force-push, or independent bump.
- **Trigger and evidence:** Current retry refuses pre-tag with `recorded release source does not match the immutable snapshot`.
- **Completed and verified:** Source implementation and prerequisite aggregation fixes merged; current snapshot resolver returns six immutable PR@merge-SHA entries.
- **Remaining acceptance criteria:** Merge this fix, retry safely, and verify all terminal publication channels and receipt.
- **Unsafe route not to repeat:** Trailer-subset retries or manual lane/authorization edits.
- **Next safe route:** Correct and verify the validator, merge through normal gates, then use the canonical release command and reconcile loop.
- **Resume condition:** Fix merged to current `main`, retained lane still tagless, and channels still absent.
- **Owner and status:** AI DevOps interactive session; recovering.

### Files Scope

- `.agents/scripts/full-loop-release-aggregate-recovery.sh`
- `.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh`
- `TODO.md`
- `todo/tasks/t18441-brief.md`

## Acceptance Criteria

- [ ] A tagless failed source authorized in the persisted manifest can retry through a newer complete resolver snapshot when the old authorization is a valid subset.
- [ ] Exact-snapshot, direct, and aggregate retry behavior remains accepted.
- [ ] Missing, extra, duplicate, malformed, SHA-conflicting, source-unbound, or expected-manifest-conflicting snapshots are refused before mutation.
- [ ] The focused recovery suite, ShellCheck, and changed-file lint pass.
- [ ] The fix PR merges through required checks and the retained release lane can advance without overrides or manual state edits.

## Context & Decisions

- Preserve exact equality between resolver output and the caller-reviewed expected source manifest.
- Relax only persisted-authorization equality to a subset relation; never accept a source absent from persisted authorization.
- Keep mutation, fencing, publication-channel checks, and release-type binding unchanged.
- Prior art: GH#31897 / PR #31901 added snapshot retries but coupled the recorded failed source to the latest snapshot tip.

## Relevant Files

- `.agents/scripts/full-loop-release-aggregate-recovery.sh:361-415` — failing trust-boundary validator.
- `.agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh:984-1032` — direct/aggregate/snapshot retry tests.
- `.agents/scripts/release-authorization-manifest-helper.sh` — canonical exact comparison, subset, and normalization helpers.

## Dependencies

- **Blocked by:** none
- **Blocks:** Minor incremental release for source PR #31958.
- **External:** GitHub and publication-channel reads during final release reconciliation; no new credentials.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Persisted evidence, prior fix, validator, focused tests |
| Implementation | 45m | Validator invariants and regression cases |
| Verification | 45m | Focused suite, ShellCheck, changed-file lint, PR gates |
| **Total** | **~2h** | |
