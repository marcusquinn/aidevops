<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18128: Cache PR check status by head SHA and refresh actionable changes

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `PR check status head SHA cache actionable refresh` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 related target-file commits / 0 overlapping open PRs; sequential per-PR REST enrichment remains at HEAD
- [x] File refs verified: 5 source/test surfaces checked, all present at `313548fc6` or verified new-file parents
- [x] Tier: `tier:standard` — deterministic immutable-head cache with bounded freshness and final-authority exclusions
- [x] Seeded draft PR decision recorded: skipped — blocked until canonical snapshot reuse from t18127 is merged

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** t18127 through a native GitHub blocked-by relationship
- **Conversation context:** `gh_pr_check_status_rest_batch` loops over every PR and calls `/commits/{sha}/check-suites` each cycle. Commit SHAs are immutable, so terminal aggregate states can be reused by SHA while pending/unknown states need bounded refresh and final merge checks remain authoritative.

## What

Add a versioned PR check-status cache keyed by repository, exact head SHA, and check projection. Reuse terminal states for unchanged heads, refresh pending/unknown entries on short TTL or explicit invalidation, and fetch only new/expired/actionable heads during prefetch. Preserve separate detailed check-run/status reads for single-PR required-context gates and prohibit cache data from authorising a final merge.

## Why

The current batch function at `shared-gh-wrappers-checks.sh:243-280` makes one REST call for every open PR on every enrichment pass. Most heads and terminal check outcomes do not change. Keying cache entries to immutable head SHA removes repeated calls without conflating new commits, but the aggregate `PASS/FAIL/PENDING/none` view is insufficient for final required-check policy and must remain advisory prefetch data.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — wrapper, prefetch integration, cache tests, and API-budget tests coordinate.
- [ ] **Every target file under 500 lines?** No — prefetch integration exceeds 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — TTL and invalidation boundaries require judgment.
- [ ] **No judgment or design decisions?** No — terminal versus actionable states have different refresh policy.
- [ ] **No error handling or fallback logic to design?** No — API failure and unknown checks must remain non-authoritative.
- [ ] **No cross-package or cross-module changes?** No — shared wrapper and Pulse consumer change together.
- [ ] **Estimate 1h or less?** No — estimated two hours.
- [ ] **4 or fewer acceptance criteria?** No — immutable keys, pending refresh, detailed gates, and budgets need separate proof.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:standard`

**Tier rationale:** Immutable SHA keying is a strong existing primitive, but refresh classes and final-authority exclusions require bounded cross-module judgment.

## PR Conventions

Leaf task. The implementation PR closes only this issue and references parent t18124 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Integration must use the final canonical PR snapshot/projection from t18127.
- **Status:** `blocked`
- **Freshness evidence:** Check-suite wrapper, detailed check paths, batch loop, and prefetch caller were checked at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check merge preflight and required-check modules before deciding which consumers may read aggregate cache data.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/shared-gh-wrappers-checks.sh:90-128,131-225,227-280` — aggregate versus detailed check contracts and sequential batch loop.
- **Then read:** `.agents/scripts/pulse-prefetch-fetch.sh:130-179,251-265` — prefetch enrichment and display-only consumption.
- **Load only if:** a final merge consumer appears to use the aggregate helper — inspect `.agents/scripts/pulse-merge-required-checks.sh` and `.agents/scripts/pulse-merge.sh:1397-1455` before allowing cache reuse.
- **Reference test:** `.agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh` — source/request budget assertion style.
- **Why:** Aggregate cache data can accelerate observation but cannot replace named required-context and exact-head final checks.
- **Stop when:** repeated unchanged heads cause zero check-suite requests and every changed/pending/invalid entry follows the documented refresh path.

### Worker Quick-Start

```bash
rg -n 'gh_pr_check_status_rest|gh_pr_check_status_rest_batch|_prefetch_prs_enrich_checks|headRefOid' .agents/scripts/shared-gh-wrappers-checks.sh .agents/scripts/pulse-prefetch-fetch.sh
rg -n 'gh_pr_check_runs_rest|preflight_snapshot|required.check' .agents/scripts/pulse-merge*.sh
```

### Files to Modify

- `EDIT: .agents/scripts/shared-gh-wrappers-checks.sh:90-128,227-280` — add cache get/put/invalidate helpers and fetch only unique missing/actionable head SHAs.
- `EDIT: .agents/scripts/pulse-prefetch-fetch.sh:130-179,251-265` — pass canonical PR head data once and expose cache/fetch classifications in telemetry.
- `NEW: .agents/scripts/tests/test-gh-check-status-cache.sh` — immutable-head, pending TTL, corruption, API failure, and concurrency fixtures.
- `EDIT: .agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh` — add or adapt a source-level budget asserting no per-cycle unchanged-head fan-out.
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh` — preserve PASS/FAIL/PENDING display and failure-routing expectations.

### Complete Write Surface

- **Callers/readers:** `_prefetch_prs_enrich_checks` calls the batch aggregate helper; PR formatting reads `{number,status}`. Named required-check gates use `gh_pr_check_runs_rest` and remain separate.
- **Writers/mutation paths:** `.agents/scripts/shared-gh-wrappers-checks.sh` cache helpers atomically write versioned slug/SHA/projection entries; its API fetch remains the only status producer and t18130 calls its invalidator.
- **Tests/fixtures:** `.agents/scripts/tests/test-gh-check-status-cache.sh`, `.agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh`, and `.agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh` stub responses/time and guard behavior/request count.
- **Schemas/config:** `.agents/scripts/shared-gh-wrappers-checks.sh` owns schema version, repository, head SHA, projection, state, fetched timestamp, expiry class, source, validation outcome, and validated TTL defaults.
- **Generated/deployed mirrors:** `.agents/scripts/shared-gh-wrappers-checks.sh` deploys through setup; runtime cache is private, disposable, and untracked.
- **Migrations/backfills:** `.agents/scripts/shared-gh-wrappers-checks.sh` performs no backfill; legacy/missing cache is a miss and new commits naturally use new keys.
- **Cleanup/rollback paths:** Disabling or reverting `.agents/scripts/shared-gh-wrappers-checks.sh` cache helpers restores direct check-suite reads; final merge paths remain live throughout rollout.

### Implementation Steps

1. Create a stable cache key from sanitized repository identity, full head SHA, and aggregate check-suite projection version. Never key only by PR number, branch, `updatedAt`, or short SHA.
2. Classify entries: terminal `PASS`/`FAIL` may use a longer bounded TTL; `PENDING` and `none` use short TTLs; malformed/API-failed responses are not successful entries.
3. Deduplicate identical SHAs in the batch, read all valid entries first, fetch only misses/expired/actionable states, and atomically store successful responses.
4. Preserve output order and one `{number,status}` result per input PR even when multiple PRs share a SHA. Emit cache-hit/miss/refresh transport telemetry from t18125.
5. Keep `gh_pr_check_runs_rest` and final preflight snapshot live/fail-closed for named required checks, review gates, and merge authority. Add an explicit comment/test preventing aggregate cache promotion into that path.
6. Expose an idempotent invalidation interface by slug/SHA for t18130 without implementing webhooks in this phase.

### Hazards and Compatibility

- **Concurrency/atomicity:** Multiple processes can miss the same SHA until t18129 adds single-flight. Writes must be atomic and tolerate last-writer-wins only for identical immutable keys.
- **Migration/rollback:** Cache is additive/disposable; disabling it restores current direct calls without data migration.
- **Mixed-version/backward compatibility:** Old consumers receive the same `{number,status}` array. Unknown schema versions are misses, not trusted entries.
- **Idempotency/retry:** Duplicate PRs/SHAs produce one fetch; repeated invalidation/deletion is safe; API failure does not overwrite a valid terminal entry with fabricated `none`.
- **Partial failure/recovery:** Partial batch success returns cached/fetched statuses where valid and explicit `none` for failed observations, but never authorises merge or suppresses required-check repair.

### Complexity Impact

- **Target functions:** `gh_pr_check_status_rest`, `gh_pr_check_status_rest_batch`, and `_prefetch_prs_enrich_checks`.
- **Current line count:** The batch function is about 38 lines; shared file is 281 lines.
- **Estimated growth:** About 100 lines of cohesive cache helpers plus tests.
- **Projected post-change:** Inlining cache policy into the batch loop would approach complexity thresholds.
- **Action required:** Put key, read, write, expiry, and invalidation in small helpers; keep the batch function orchestration-only.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-gh-check-status-cache.sh
bash .agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh
bash .agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh
shellcheck .agents/scripts/shared-gh-wrappers-checks.sh .agents/scripts/pulse-prefetch-fetch.sh .agents/scripts/tests/test-gh-check-status-cache.sh .agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh .agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Cache fixtures prove immutable keys/TTL/failure semantics; prefetch tests preserve displayed/routed state; budget tests prove unchanged-head fan-out removal; lint covers portability.
- **Broad verification trigger:** Required only if implementation touches final merge/required-check consumers, which must then run their focused suites too.

### Recoverability Checkpoint

- [ ] Focused tests pass: cache, CI-failure prefetch, and request-budget suites
- [ ] WIP commit created before broad gates: `wip: cache PR checks by head SHA`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Remove repeated per-PR check-suite reads while preserving exact-head required-check authority.
- **Preserved user directions:** Refresh actionable changes only and prove savings with transport telemetry.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Aggregate, detailed, batch, and prefetch check paths identified.
- **Remaining acceptance criteria:** All implementation and canary criteria below.
- **Unsafe route not to repeat:** Do not key by PR number or use aggregate cached PASS as final merge authority.
- **Next safe route:** Build fixture cache helpers first, then integrate only the prefetch batch consumer.
- **Resume condition:** t18127 is closed and canonical PR snapshots include full head SHA.
- **Owner and status:** Build+ `tier:standard`; blocked by t18127.

### Files Scope

- `.agents/scripts/shared-gh-wrappers-checks.sh`
- `.agents/scripts/pulse-prefetch-fetch.sh`
- `.agents/scripts/tests/test-gh-check-status-cache.sh`
- `.agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh`
- `.agents/scripts/tests/test-pulse-wrapper-ci-failure-prefetch.sh`
- `.agents/scripts/pulse-merge-required-checks.sh`
- `.agents/scripts/pulse-merge.sh`

## Acceptance Criteria

- [ ] Cache keys include repository, full immutable head SHA, and projection version; a new head always misses the old entry.
- [ ] Repeated prefetch of unchanged terminal heads makes zero check-suite transport attempts until bounded expiry or explicit invalidation.
- [ ] Pending/none states refresh on a short deterministic TTL, malformed/API-failed results are not trusted successes, and output order/cardinality remain compatible.
- [ ] Duplicate input SHAs produce one fetch and one reusable cache entry without leaking state across repositories or auth scopes.
- [ ] Named required-check and final merge gates never use aggregate cache state as positive authority and remain exact-head/fail-closed.
- [ ] Focused tests, ShellCheck, changed lint, required CI, and t18125 telemetry show lower per-cycle REST attempts before t18129 is promoted.

## Context & Decisions

- Full commit SHA is the immutable identity; PR number and timestamps are not.
- Terminal aggregate cache accelerates prefetch observation only.
- Pending and unknown state remain actionable and receive short refresh windows.

## Relevant Files

- `.agents/scripts/shared-gh-wrappers-checks.sh:90-128` — aggregate check-suite state.
- `.agents/scripts/shared-gh-wrappers-checks.sh:131-225` — detailed named checks that remain live for policy.
- `.agents/scripts/shared-gh-wrappers-checks.sh:227-280` — current one-request-per-PR batch loop.
- `.agents/scripts/pulse-prefetch-fetch.sh:251-265` — batch enrichment consumer.

## Dependencies

- **Blocked by:** t18127.
- **Blocks:** t18129.
- **External:** GitHub check-suite fixtures; no new service or secret.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read/design | 30m | Cache classes and authority boundary |
| Implementation | 60m | Helpers, batch integration, invalidation hook |
| Tests/canary | 30m | TTL, budget, compatibility |
| **Total** | **2h** | |
