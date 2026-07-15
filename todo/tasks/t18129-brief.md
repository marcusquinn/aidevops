<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18129: Add cross-process single-flight and shared rate-limit state

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GitHub API single-flight shared rate-limit cache cross-process` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 related target-file commits / 0 overlapping open PRs; process-local fallback and shared circuit cache remain separate
- [x] File refs verified: 7 source/test/reference surfaces checked, all present at `313548fc6` or verified new-file parents
- [x] Tier: `tier:thinking` — concurrency, stale-lock recovery, auth-scope isolation, and mixed-version behavior require architectural judgment
- [x] Seeded draft PR decision recorded: skipped — blocked until head-SHA cache behavior from t18128 is stable

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** t18128 through a native GitHub blocked-by relationship
- **Conversation context:** `_rest_should_fallback` caches GraphQL remaining only in process globals for 20 seconds, while `pulse-rate-limit-circuit-breaker.sh` already maintains an atomic shared file. Concurrent Pulse helpers can still query rate state or fetch the same snapshot/check SHA simultaneously.

## What

Introduce one small shared request-coordination module that provides auth-scope-safe rate-limit snapshots and bounded cross-process single-flight for cacheable GitHub reads. Consolidate `_rest_should_fallback` and the circuit breaker on the same versioned rate state, let one leader perform an eligible miss while followers reuse its atomic result, and recover safely from crashed leaders, stale locks, timeouts, and mixed versions.

## Why

Process-local caches do not suppress duplicate `/rate_limit` probes or simultaneous identical misses across Pulse, webhook, merge, and worker processes. Independent caches can also disagree about whether GraphQL is exhausted. A shared state contract reduces burst amplification, but careless locking can deadlock automation or leak responses between credentials/repositories, so keying, fencing, timeout, and failure semantics must be explicit.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — new coordination module, two rate consumers, cache provider integration, and tests coordinate.
- [ ] **Every target file under 500 lines?** No — REST fallback exceeds 1,500 lines.
- [ ] **Exact oldString/newString for every edit?** No — lock/state protocol must be designed.
- [ ] **No judgment or design decisions?** No — request eligibility and auth-scope isolation are architectural.
- [ ] **No error handling or fallback logic to design?** No — crashed leaders, stale locks, timeout, and API uncertainty are core behavior.
- [ ] **No cross-package or cross-module changes?** No — shared wrappers, circuit breaker, prefetch/check caches, and tests interact.
- [ ] **Estimate 1h or less?** No — estimated two hours.
- [ ] **4 or fewer acceptance criteria?** No — concurrency and compatibility need a broad fixture matrix.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:thinking`

**Tier rationale:** Cross-process coordination is correctness-sensitive. The worker must design a bounded lock/result protocol without introducing a new daemon or weakening fail-closed API behavior.

## PR Conventions

Leaf task. The implementation PR closes only this issue and references parent t18124 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Single-flight keys and eligible result classes must use the final snapshot/check cache schemas from preceding leaves.
- **Status:** `blocked`
- **Freshness evidence:** Process-local fallback cache, shared circuit cache, and lock reference implementations were checked at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check any rate-limit or request-coordination changes merged after t18128 before choosing the canonical owner module.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:292-342` and `.agents/scripts/pulse-rate-limit-circuit-breaker.sh:79-159` — duplicate process-local/shared state and existing atomic cache.
- **Then read:** t18127/t18128 merged cache helpers — identify only exact, cacheable, read-only operations eligible for single-flight.
- **Reference pattern:** `.agents/scripts/pulse-fast-fail.sh` lock wrapper and `.agents/scripts/pulse-events-tickle.sh:104-118` atomic cache write; copy stale-lock and temp/rename mechanics, not business logic.
- **Load only if:** lock complexity approaches repository gates — use `.agents/reference/large-file-split.md` and keep the new module cohesive.
- **Why:** Shared coordination must save requests without serialising unrelated repositories, credentials, or mutations.
- **Stop when:** a multi-process fixture elects one leader, followers reuse one result, stale/crashed leaders recover, and both rate consumers read one state.

### Worker Quick-Start

```bash
rg -n '_GH_REST_FALLBACK_RATE_LIMIT_CACHE|_rest_should_fallback|_CB_RL_CACHE_FILE|_cb_rate_limit_json' .agents/scripts/shared-gh-wrappers-rest-fallback.sh .agents/scripts/pulse-rate-limit-circuit-breaker.sh
rg -n '_ff_with_lock|mkdir .*lock|flock|stale' .agents/scripts/pulse-fast-fail.sh .agents/scripts/worker-activity-watchdog.sh
```

### Files to Modify

- `NEW: .agents/scripts/shared-gh-request-state.sh` — versioned shared rate snapshot plus bounded keyed single-flight primitives.
- `EDIT: .agents/scripts/shared-gh-wrappers-rest-fallback.sh:292-342` — replace process globals as authority with the shared rate snapshot while retaining optional precomputed remaining input.
- `EDIT: .agents/scripts/pulse-rate-limit-circuit-breaker.sh:79-159` — delegate cache read/write to the shared module and preserve circuit policy/output.
- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh` — wrap only exact canonical snapshot misses in keyed single-flight.
- `EDIT: .agents/scripts/shared-gh-wrappers-checks.sh` — wrap only identical slug/SHA aggregate check misses in keyed single-flight.
- `NEW: .agents/scripts/tests/test-gh-request-singleflight.sh` — concurrent leader/follower/crash/timeout/auth-scope fixtures.
- `EDIT: .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh` and `.agents/scripts/tests/test-rate-limit-circuit-breaker.sh` — prove one shared rate source and existing policy compatibility.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/shared-gh-wrappers-rest-fallback.sh` and `.agents/scripts/pulse-rate-limit-circuit-breaker.sh` read shared rate state; exact cache misses in the batch/check helpers may enter single-flight.
- **Writers/mutation paths:** `.agents/scripts/shared-gh-request-state.sh` lets one leader atomically write response/rate metadata and owner generation/lease state, then remove only its own lease.
- **Tests/fixtures:** `.agents/scripts/tests/test-gh-request-singleflight.sh`, `.agents/scripts/tests/test-gh-wrapper-rest-fallback.sh`, and `.agents/scripts/tests/test-rate-limit-circuit-breaker.sh` use concurrent shells/counting stubs and preserve policy.
- **Schemas/config:** `.agents/scripts/shared-gh-request-state.sh` owns version, auth-scope fingerprint, pool, observed/reset timestamps, remaining/limit, key hash, owner start, lease expiry, generation, and completion state.
- **Generated/deployed mirrors:** `.agents/scripts/shared-gh-request-state.sh` deploys through setup and is sourced by existing modules; runtime coordination files are private and untracked.
- **Migrations/backfills:** `.agents/scripts/pulse-rate-limit-circuit-breaker.sh` may adapt the existing cache once or treat it as a cold miss; no destructive migration occurs.
- **Cleanup/rollback paths:** Flags in `.agents/scripts/shared-gh-request-state.sh` bypass single-flight/shared state and restore direct behavior; stale files are lease-expired and removable.

### Implementation Steps

1. Define a sanitized scope fingerprint from credential/auth mode and API pool without storing token material. Include repository, operation/projection version, and normalized request identity in single-flight keys.
2. Implement atomic shared rate-state read/write with TTL and reset awareness. Preserve `_rest_should_fallback remaining` as the zero-I/O fast path and return unknown distinctly from exhausted.
3. Implement leader election using an atomic lock/lease directory or existing portable lock helper. Store owner/generation/expiry, bound follower wait, and require owner/generation match before release or result publish.
4. Permit only idempotent, exact, cacheable reads: canonical issue/PR snapshots and aggregate check status by immutable SHA. Exclude writes, comments, labels, merges, auth probes, named final checks, and arbitrary gh commands.
5. Followers wait with bounded jitter, consume only a validated matching result, and on timeout/stale leader either elect a new leader or follow existing fail-closed/direct fallback policy. Never spin indefinitely.
6. Consolidate fallback and circuit-breaker rate reads on the module, then add concurrent fixtures proving one probe/fetch and no cross-scope reuse.

### Hazards and Compatibility

- **Concurrency/atomicity:** PID reuse, crashed leaders, delayed writers, and ABA lock replacement require generation/fencing checks plus atomic rename. Never delete a lease owned by another generation.
- **Migration/rollback:** New state is additive and disposable. Disable switches restore current process-local/direct paths; legacy cache is never trusted across auth scopes without validation.
- **Mixed-version/backward compatibility:** Old processes may ignore new locks and make extra calls but must not corrupt results. New readers reject unknown schema/version and use bounded fallback.
- **Idempotency/retry:** Only read-only exact operations enter single-flight. Repeated completion/release is safe; a retry after failed leader never reuses partial output.
- **Partial failure/recovery:** API/network failure is published only as a short-lived typed failure when safe, not as empty success. Followers time out to current safe behavior and telemetry records coalesced, waited, takeover, and bypass outcomes.

### Complexity Impact

- **Target functions:** `_rest_should_fallback`, `_cb_rate_limit_json`, canonical fetch/check miss paths.
- **Current line count:** REST fallback is a large file; target functions are moderate but frequently called.
- **Estimated growth:** New module about 150 lines plus focused adapters/tests.
- **Projected post-change:** Inlining lock protocol into existing functions would exceed complexity and duplicate literals.
- **Action required:** Keep protocol in `shared-gh-request-state.sh` with small explicit-return functions; adapters should be under 20 lines each.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-gh-request-singleflight.sh
bash .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh
bash .agents/scripts/tests/test-rate-limit-circuit-breaker.sh
shellcheck .agents/scripts/shared-gh-request-state.sh .agents/scripts/shared-gh-wrappers-rest-fallback.sh .agents/scripts/pulse-rate-limit-circuit-breaker.sh .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/shared-gh-wrappers-checks.sh .agents/scripts/tests/test-gh-request-singleflight.sh .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh .agents/scripts/tests/test-rate-limit-circuit-breaker.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Multi-process fixtures prove election/fencing/scope/recovery; existing fallback and circuit tests prove policy compatibility; ShellCheck/changed lint cover portability and shared-module integration.
- **Broad verification trigger:** Required because a shared module changes multiple API routing paths; run normal required CI after focused tests and WIP checkpoint.

### Recoverability Checkpoint

- [ ] Focused tests pass: single-flight, REST fallback, and circuit-breaker suites
- [ ] WIP commit created before broad gates: `wip: coordinate shared GitHub request state`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Coalesce identical GitHub reads and unify rate-limit state across processes without deadlock or authority leaks.
- **Preserved user directions:** Reduce burst pressure only after earlier cache semantics are verified.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Process-local and shared rate caches plus eligible prior-phase reads identified.
- **Remaining acceptance criteria:** All implementation and concurrency criteria below.
- **Unsafe route not to repeat:** Do not single-flight writes, final merge authority, arbitrary commands, or requests across auth scopes.
- **Next safe route:** Implement isolated multi-process fixtures before integrating any production caller.
- **Resume condition:** t18128 is closed and its cache miss interfaces are stable.
- **Owner and status:** Build+ `tier:thinking`; blocked by t18128.

### Files Scope

- `.agents/scripts/shared-gh-request-state.sh`
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh`
- `.agents/scripts/pulse-rate-limit-circuit-breaker.sh`
- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/shared-gh-wrappers-checks.sh`
- `.agents/scripts/tests/test-gh-request-singleflight.sh`
- `.agents/scripts/tests/test-gh-wrapper-rest-fallback.sh`
- `.agents/scripts/tests/test-rate-limit-circuit-breaker.sh`

## Acceptance Criteria

- [ ] Concurrent identical eligible reads under one auth/repository/projection key produce one leader transport attempt and validated follower reuse.
- [ ] Shared rate state is the common source for REST fallback and circuit-breaker reads, respects TTL/reset, and keeps unknown distinct from zero/exhausted.
- [ ] Scope keys prevent reuse across repositories, credential scopes, API pools, projections, or head SHAs without storing credential material.
- [ ] Crashed, timed-out, stale, and PID-reused leaders recover through generation/fencing checks without indefinite waits, partial-result reuse, or foreign-lock deletion.
- [ ] Mutations, arbitrary gh calls, detailed/final required checks, and merge authority never enter single-flight.
- [ ] Mixed-version/disabled mode remains safe, and focused tests plus t18125 telemetry show lower duplicate attempts and burst concurrency before t18130 is promoted.

## Context & Decisions

- Consolidate around the existing shared circuit cache rather than add another independent rate cache.
- Single-flight applies only after exact cache key and success semantics exist.
- Extra calls during mixed-version rollout are acceptable; stale positive authority or deadlock is not.

## Relevant Files

- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:292-342` — current process-local 20-second cache.
- `.agents/scripts/pulse-rate-limit-circuit-breaker.sh:79-159` — existing atomic shared rate-limit cache.
- `.agents/scripts/pulse-fast-fail.sh` — portable lock/stale-recovery reference.
- `.agents/scripts/pulse-batch-prefetch-helper.sh` — canonical collection miss path.
- `.agents/scripts/shared-gh-wrappers-checks.sh` — immutable-head aggregate check miss path.

## Dependencies

- **Blocked by:** t18128.
- **Blocks:** t18130.
- **External:** None; concurrency tests use local processes and stub transports.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Protocol design | 30m | Scope, lease, fencing, failure semantics |
| Implementation | 60m | Shared module and adapters |
| Tests/canary | 30m | Multi-process fixtures and telemetry |
| **Total** | **2h** | |
