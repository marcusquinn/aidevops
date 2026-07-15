<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18127: Reuse canonical snapshots and remove duplicate verification reads

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `canonical GitHub snapshot fingerprint verification duplicate requests` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 target-file commits / 0 overlapping open PRs; fingerprint and verification live-list paths remain at HEAD
- [x] File refs verified: 6 source/test surfaces checked, all present at `313548fc6` or verified new-file parents
- [x] Tier: `tier:standard` — replace redundant reads with an established canonical snapshot while preserving fail-closed freshness checks
- [x] Seeded draft PR decision recorded: skipped — blocked until empty snapshots are proven authoritative by t18126

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** t18126 through a native GitHub blocked-by relationship
- **Conversation context:** `_compute_repo_state_fingerprint` performs fresh issue and PR lists, then `_verify_repo_state_unchanged` performs two more lists before prefetch runs. Batch and exact-output caches already hold enough canonical state to derive fingerprints locally and centralise refresh decisions.

## What

Make one validated per-repository issue/PR snapshot the source for Pulse prefetch, local state fingerprints, cache-hit decisions, and downstream list projections. Remove the dedicated fingerprint and post-fingerprint verification list requests. Refresh only through the canonical provider using its conditional/TTL contract, while preserving bounded polling and final live authority checks for dispatch and merge.

## Why

`pulse-prefetch-infra.sh:229-245` lists issues and PRs to hash state, and lines 341-367 list both collections again to verify unchanged state. Those requests duplicate the data fetched by batch/prefetch providers and increase burst pressure before useful work starts. Local derivation from one canonical snapshot is cheaper and easier to reason about, provided source completeness and freshness are explicit.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — snapshot provider, prefetch consumer, fingerprint logic, and tests coordinate.
- [ ] **Every target file under 500 lines?** No — the Pulse prefetch helpers exceed 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — canonical projection and completeness metadata require adaptation.
- [ ] **No judgment or design decisions?** No — local derivation must distinguish complete from partial snapshots.
- [ ] **No error handling or fallback logic to design?** No — stale, partial, and provider-failed paths remain fail-closed.
- [ ] **No cross-package or cross-module changes?** No — provider and consumers span several shell modules.
- [ ] **Estimate 1h or less?** No — estimated 1.5 hours.
- [ ] **4 or fewer acceptance criteria?** No — API budget, completeness, compatibility, and correctness each need evidence.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:standard`

**Tier rationale:** The implementation adapts existing batch and exact-output provider patterns. It needs coordinated fallback judgment but does not create a novel storage system.

## PR Conventions

Leaf task. The implementation PR closes only this issue and references parent t18124 without closing it.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Snapshot reuse depends on the final hit-empty contract from t18126 and must not guess its metadata shape.
- **Status:** `blocked`
- **Freshness evidence:** Fingerprint, verification, cache-read, and repo-prefetch call sites were checked at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-read the t18126 merged cache contract before editing any provider or consumer.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-prefetch-infra.sh:210-367,425-460` — current live fingerprint and verification flow.
- **Then read:** `.agents/scripts/pulse-batch-prefetch-helper.sh:291-430,760-846` and `.agents/scripts/pulse-prefetch-fetch.sh:182-389` — normalized snapshot producer and consumers.
- **Reference pattern:** `.agents/scripts/pulse-pr-list-cache.sh:32-131` — exact argv/output preservation for GraphQL-only PR projections.
- **Load only if:** repo cache update flow changes — inspect `.agents/scripts/pulse-prefetch-repo.sh` and `_prefetch_cache_set` in `pulse-prefetch-infra.sh`.
- **Why:** A fingerprint is useful only when derived from the same complete snapshot that consumers will act on.
- **Stop when:** steady-state prefetch has no dedicated fingerprint/verification list calls and incomplete state cannot produce a cache hit.

### Worker Quick-Start

```bash
rg -n '_compute_repo_state_fingerprint|_verify_repo_state_unchanged|_prefetch_detect_cache_hit|read-cache|pulse_pr_list_get' .agents/scripts/pulse-prefetch-*.sh .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-pr-list-cache.sh
bash .agents/scripts/tests/test-pulse-wrapper-delta-prefetch.sh
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-prefetch-infra.sh:210-367,425-460` — derive fingerprint/cache-hit state from canonical snapshot metadata and delete dedicated verification lists.
- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh:291-430,760-846` — expose complete normalized snapshot data plus source/freshness/completeness needed by local consumers.
- `EDIT: .agents/scripts/pulse-prefetch-fetch.sh:182-389` — consume the same snapshot for issue/PR output without independent list refreshes.
- `EDIT: .agents/scripts/pulse-prefetch-repo.sh` — thread one snapshot/result through the per-repository prefetch cycle rather than re-resolving providers.
- `EDIT: .agents/scripts/pulse-pr-list-cache.sh:32-131` — align exact-output reuse with canonical provider metadata only where semantics remain exact.
- `NEW: .agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh` — request-budget and completeness regression harness modelled on delta/batch prefetch tests.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/pulse-prefetch-repo.sh`, `.agents/scripts/pulse-prefetch-infra.sh`, and `.agents/scripts/pulse-prefetch-fetch.sh` consume snapshot output for per-repo prefetch, fingerprints, cache-hit detection, and markdown generation.
- **Writers/mutation paths:** `.agents/scripts/pulse-batch-prefetch-helper.sh` writes normalized collection files; `.agents/scripts/pulse-prefetch-infra.sh` writes the summary cache and locally derived fingerprint metadata.
- **Tests/fixtures:** New canonical-snapshot test plus `test-pulse-wrapper-delta-prefetch.sh`, `test-enrich-batch-prefetch.sh`, and conditional REST fixtures cover full, delta, empty, partial, and failed states.
- **Schemas/config:** `.agents/scripts/pulse-batch-prefetch-helper.sh` extends the t18126 contract with collection, projection, completeness, source, fetched timestamp, and validator metadata; legacy complete arrays remain readable.
- **Generated/deployed mirrors:** `.agents/scripts/` sources deploy through setup; runtime cache files are disposable and untracked.
- **Migrations/backfills:** `.agents/scripts/pulse-batch-prefetch-helper.sh` performs no eager backfill; first provider refresh populates metadata and legacy state without provable completeness follows the existing refresh path.
- **Cleanup/rollback paths:** A flag or revert in `.agents/scripts/pulse-prefetch-infra.sh` restores live fingerprint/verification queries; deleting snapshot caches forces a safe cold refresh.

### Implementation Steps

1. Define a canonical snapshot envelope keyed by repository, collection, exact projection/schema, and auth scope. Include `items`, `fetched_at`, `source`, `complete`, and conditional validators without changing normalized item semantics.
2. Fetch/read each issue and PR collection once per cycle and pass the validated result through repo prefetch. Do not reopen the provider for fingerprint, output, or cache-hit checks.
3. Compute the existing deterministic fingerprint from the canonical issue/PR arrays locally. A missing, stale, malformed, truncated, paginated-incomplete, or projection-incompatible collection yields no cache hit.
4. Remove `_verify_repo_state_unchanged` network lists. The canonical provider's conditional request or bounded TTL is the only periodic refresh path until webhook invalidation ships in t18130.
5. Preserve exact-output `pulse_pr_list_get` for callers requiring fields absent from the normalized snapshot; key by exact argv and never substitute a narrower projection.
6. Add a stub-gh request ledger proving one provider decision per collection, zero fingerprint/verification list calls, and correct fallback for incomplete snapshots.

### Hazards and Compatibility

- **Concurrency/atomicity:** Snapshot files and repo summary cache must remain atomic; a reader cannot combine issue data from one generation with PR metadata from another without marking the composite partial.
- **Migration/rollback:** Legacy entries lacking completeness metadata refresh rather than being trusted. Revert or cache deletion restores prior behavior.
- **Mixed-version/backward compatibility:** New envelopes retain `.items` and normalized fields for old readers; new readers do not trust legacy completeness for a skip decision.
- **Idempotency/retry:** Repeated local fingerprint/output derivation performs no writes or requests. Failed conditional refresh keeps the last snapshot only for non-authoritative display paths allowed by existing policy.
- **Partial failure/recovery:** One failed collection marks the composite incomplete and prevents a deep-analysis skip; it never fabricates empty state or suppresses final live gates.

### Complexity Impact

- **Target functions:** `_compute_repo_state_fingerprint`, `_verify_repo_state_unchanged`, `_prefetch_detect_cache_hit`, and per-repo prefetch orchestration.
- **Current line count:** `_compute_repo_state_fingerprint` is roughly 95 lines and near the function-complexity limit.
- **Estimated growth:** Net source should shrink by deleting live-query logic, with new snapshot parsing helpers under 40 lines each.
- **Projected post-change:** Inlining envelope validation would exceed safe complexity.
- **Action required:** Replace the current fingerprint body with small pure helpers for snapshot validation and canonical hashing; delete rather than wrap redundant query code.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh
bash .agents/scripts/tests/test-pulse-wrapper-delta-prefetch.sh
bash .agents/scripts/tests/test-enrich-batch-prefetch.sh
shellcheck .agents/scripts/pulse-prefetch-infra.sh .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-prefetch-fetch.sh .agents/scripts/pulse-prefetch-repo.sh .agents/scripts/pulse-pr-list-cache.sh .agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The new ledger proves request removal and completeness gating; delta/enrich tests preserve existing output behavior; ShellCheck/changed lint cover shell and repository invariants.
- **Broad verification trigger:** Required only if provider schema changes affect non-Pulse callers discovered during implementation.

### Recoverability Checkpoint

- [ ] Focused tests pass: canonical-snapshot, delta-prefetch, and enrich-batch suites
- [ ] WIP commit created before broad gates: `wip: reuse canonical GitHub snapshots`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Remove duplicate GitHub state reads by deriving all prefetch state from one canonical snapshot.
- **Preserved user directions:** Preserve freshness and correctness while reducing requests.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Four redundant live-list locations and existing providers identified.
- **Remaining acceptance criteria:** All implementation and canary criteria below.
- **Unsafe route not to repeat:** Do not treat partial/narrow/legacy state as a complete canonical snapshot.
- **Next safe route:** Add fixture envelope validation before deleting live queries.
- **Resume condition:** t18126 is closed and its empty-hit contract is available.
- **Owner and status:** Build+ `tier:standard`; blocked by t18126.

### Files Scope

- `.agents/scripts/pulse-prefetch-infra.sh`
- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-prefetch-fetch.sh`
- `.agents/scripts/pulse-prefetch-repo.sh`
- `.agents/scripts/pulse-pr-list-cache.sh`
- `.agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh`
- `.agents/scripts/tests/test-pulse-wrapper-delta-prefetch.sh`
- `.agents/scripts/tests/test-enrich-batch-prefetch.sh`

## Acceptance Criteria

- [ ] One validated issue snapshot and one validated PR snapshot feed fingerprinting, cache-hit detection, and prefetch output for a repository cycle.
- [ ] A steady unchanged cycle makes no dedicated issue/PR list calls for fingerprint or `_verify_repo_state_unchanged` behavior.
- [ ] Empty complete snapshots remain valid, while stale, malformed, partial, truncated, or projection-incompatible snapshots cannot produce a cache hit.
- [ ] Exact GraphQL-only projections are never silently served from a narrower normalized snapshot, and final dispatch/merge authority remains live/fail-closed.
- [ ] Request-ledger fixtures show the expected per-cycle transport budget and no duplicate provider resolution.
- [ ] Focused tests, ShellCheck, changed lint, required CI, and t18125 telemetry show lower attempts before t18128 is promoted.

## Context & Decisions

- Canonical means one validated source per exact collection/projection, not one lossy object for every caller.
- Fingerprints are local derivations, not a reason to fetch state.
- Conditional refresh/TTL remains the polling backstop until verified webhook invalidation ships.

## Relevant Files

- `.agents/scripts/pulse-prefetch-infra.sh:210-367,425-460` — duplicate live fingerprint and verification reads.
- `.agents/scripts/pulse-batch-prefetch-helper.sh:291-430,760-846` — normalized canonical provider candidate.
- `.agents/scripts/pulse-prefetch-fetch.sh:182-389` — issue/PR list consumers.
- `.agents/scripts/pulse-pr-list-cache.sh:32-131` — exact-output provider semantics.

## Dependencies

- **Blocked by:** t18126.
- **Blocks:** t18128.
- **External:** None; local fixtures stub all GitHub calls.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read/design | 20m | Projection/completeness contract |
| Implementation | 45m | Thread snapshot and delete duplicate reads |
| Tests/canary | 25m | Ledger and compatibility fixtures |
| **Total** | **1.5h** | |
