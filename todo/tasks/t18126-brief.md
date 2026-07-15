<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18126: Preserve empty snapshots and canonicalise cache semantics

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `empty snapshot cache hit miss stale canonical semantics` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 related target-file commits / 0 overlapping open PRs; current empty-array rejection remains at HEAD
- [x] File refs verified: 5 source/test surfaces checked, all present at `313548fc6`
- [x] Tier: `tier:standard` — bounded cache-contract repair adapting existing exit-status and exact-output patterns
- [x] Seeded draft PR decision recorded: skipped — blocked until t18125 baseline evidence is merged

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Blocked by:** t18125 through a native GitHub blocked-by relationship
- **Conversation context:** `read-cache` already returns exit zero for a fresh successful empty array and exit one for miss/stale, but both PR and issue consumers erase the status with `||` and reject `[]`, causing unnecessary live lists.

## What

Define one canonical snapshot-result contract and update prefetch producers/consumers so a successful fresh empty array is a valid cache hit. Distinguish hit-empty, hit-nonempty, stale, missing, malformed, and fetch-failed states by exit status plus explicit metadata rather than payload truthiness. Preserve existing output schemas and fail-closed behavior for malformed or uncertain data.

## Why

At `pulse-prefetch-fetch.sh:211-217` and `345-351`, command substitution converts a nonzero cache status to an empty string and then treats `[]` as a miss. Repositories with no open PRs or issues therefore repeat live requests despite having authoritative snapshots. Fixing this foundational semantic prevents later snapshot reuse from amplifying a false-miss bug.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — provider, two consumer paths, exact-output reference, and tests coordinate.
- [ ] **Every target file under 500 lines?** No — batch and prefetch helpers exceed 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — metadata placement requires bounded judgment.
- [ ] **No judgment or design decisions?** No — canonical state names and compatibility behavior must be selected.
- [ ] **No error handling or fallback logic to design?** No — malformed and failed reads remain live-fetch candidates.
- [ ] **No cross-package or cross-module changes?** No — cache producer and consumers change together.
- [ ] **Estimate 1h or less?** No — estimated 1.5 hours.
- [ ] **4 or fewer acceptance criteria?** No — empty, stale, malformed, and compatibility paths need separate coverage.
- [x] **Dispatch-path classification:** Targets do not match `.agents/configs/self-hosting-files.conf`; normal auto-dispatch is permitted.

**Selected tier:** `tier:standard`

**Tier rationale:** Existing exit-status behavior and `pulse-pr-list-cache.sh` provide concrete patterns, but coordinating metadata and fail-closed fallback across multiple helpers exceeds a mechanical edit.

## PR Conventions

Leaf task. The implementation PR closes only this issue and uses a non-closing reference to parent t18124.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The change must consume the final telemetry schema and baseline from t18125 before canary comparison.
- **Status:** `blocked`
- **Freshness evidence:** Empty-array checks and provider exit behavior were verified at `313548fc6`.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check batch-cache callers if t18125 changes recorder placement around cache events.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-batch-prefetch-helper.sh:344-430,760-846` — cache path, timestamp freshness, and current read-cache status contract.
- **Then read:** `.agents/scripts/pulse-prefetch-fetch.sh:182-268,323-389` — PR/issue consumers that discard valid empty arrays.
- **Reference pattern:** `.agents/scripts/pulse-pr-list-cache.sh:69-131` — exact-output cache uses command success, permits zero-byte/empty results, and preserves output unchanged.
- **Load only if:** cache-entry writing changes — inspect `.agents/scripts/pulse-prefetch-infra.sh:464-567` for atomic prefetch cache updates.
- **Why:** Payload content cannot distinguish a valid empty repository state from a failed fetch.
- **Stop when:** every state has one deterministic status/metadata outcome and tests prove no live call after a fresh empty hit.

### Worker Quick-Start

```bash
rg -n 'read-cache|_batch_prs|_batch_issues|!= "\[\]"|_cmd_cache_path' .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-prefetch-fetch.sh
bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh:344-430,760-846` — expose canonical snapshot state while preserving JSON-array stdout for successful reads.
- `EDIT: .agents/scripts/pulse-prefetch-fetch.sh:205-248,339-381` — branch on command success and accept `[]` as authoritative fresh data.
- `EDIT: .agents/scripts/pulse-pr-list-cache.sh:69-131` — only if a tiny shared state helper can be reused without changing exact-output semantics; otherwise retain as read-only reference.
- `EDIT: .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` — add successful empty, stale, missing, malformed, and no-live-fallback assertions.
- `EDIT: .agents/scripts/tests/test-enrich-batch-prefetch.sh` — cover both issue and PR integration paths if the existing harness already sources them.

### Complete Write Surface

- **Callers/readers:** `_prefetch_repo_prs` and `_prefetch_repo_issues` call `read-cache`; conditional REST and owner refresh paths write normalized cache files; tests invoke the helper CLI.
- **Writers/mutation paths:** Batch search/REST writers store `{timestamp,items}`; this phase may add version/state metadata but must keep atomic file replacement and normalized arrays.
- **Tests/fixtures:** `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` and `.agents/scripts/tests/test-enrich-batch-prefetch.sh` cover 200-empty, 200-nonempty, 304, stale timestamp, missing file, malformed JSON, and command failure.
- **Schemas/config:** Existing `{timestamp,items}` remains readable. Any additive `schema_version`, `source`, or validation field has a default for legacy entries.
- **Generated/deployed mirrors:** Source under `.agents/scripts/` deploys via setup; no runtime cache contents are committed.
- **Migrations/backfills:** `.agents/scripts/pulse-batch-prefetch-helper.sh` interprets legacy valid cache files from timestamp/items; corrupt files are not migrated and continue to miss safely.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/pulse-prefetch-fetch.sh` restores live fallback; new metadata is additive, and cache files can be deleted safely for cold refetch.

### Implementation Steps

1. Specify canonical states: `hit`, `stale`, `missing`, `malformed`, and `fetch-failed`, with `empty` as data cardinality rather than a miss state. Keep exit zero for any validated fresh hit, including `[]`; use nonzero for all non-hits.
2. Make `read-cache` validate that `.items` is an array and emit the normalized array unchanged. If metadata is exposed, use stderr or a separate status command/file field so stdout remains caller-compatible.
3. Rewrite PR and issue command substitutions as conditional assignments: successful command status sets `_used_batch_cache=true` regardless of array length; a nonzero status falls through to delta/full fetch.
4. Record hit-empty versus hit-nonempty cache telemetry through t18125 without counting either as an HTTP attempt.
5. Add fixtures that make live gh stubs fail if called after a fresh empty hit, then prove stale/malformed/missing entries do call the existing fallback.

### Hazards and Compatibility

- **Concurrency/atomicity:** Readers can race atomic cache replacement; keep write-to-temp plus rename and validate complete JSON after open.
- **Migration/rollback:** Additive metadata must not invalidate legacy `{timestamp,items}` files. Deleting cache remains a safe rollback.
- **Mixed-version/backward compatibility:** Old writers and new readers interoperate; old readers still see `.items`. Do not require a new field to recognise otherwise valid legacy snapshots.
- **Idempotency/retry:** Repeated reads of a fresh empty snapshot remain hits and make no network call. Failed reads do not mutate cache before fallback succeeds.
- **Partial failure/recovery:** Malformed/truncated files are misses, logged distinctly, and replaced only by a successful fetch; never convert them to authoritative empty arrays.

### Complexity Impact

- **Target functions:** `_cmd_read_cache`, `_prefetch_repo_prs`, and `_prefetch_repo_issues`.
- **Current line count:** Consumer functions are already substantial.
- **Estimated growth:** Under 40 source lines plus fixtures.
- **Projected post-change:** Inline duplication could increase both consumer functions unnecessarily.
- **Action required:** Extract one small cache-read decision helper or use the same conditional shape in both paths; keep every shell function explicit-return and Bash 3.2 compatible.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh
bash .agents/scripts/tests/test-enrich-batch-prefetch.sh
shellcheck .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-prefetch-fetch.sh .agents/scripts/pulse-pr-list-cache.sh .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh .agents/scripts/tests/test-enrich-batch-prefetch.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Conditional fixtures prove producer states and empty preservation; enrich fixtures prove both consumers avoid live fallback; ShellCheck and changed lint cover portability and repository gates.
- **Broad verification trigger:** Not required unless a shared cache schema used outside Pulse changes.

### Recoverability Checkpoint

- [ ] Focused tests pass: both batch-prefetch test commands above
- [ ] WIP commit created before broad gates: `wip: preserve empty GitHub snapshots`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Make successful empty GitHub snapshots authoritative without hiding stale or failed reads.
- **Preserved user directions:** Use t18125 telemetry to prove zero-request empty hits before later cache phases.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Provider exit status and both rejecting consumers identified.
- **Remaining acceptance criteria:** Implementation, fixture, and canary criteria below.
- **Unsafe route not to repeat:** Do not infer cache state from `-n`, `[]`, `null`, or item count alone.
- **Next safe route:** Implement status-first fixtures, then change consumers.
- **Resume condition:** t18125 is closed and its cache-event/attempt fields are available.
- **Owner and status:** Build+ `tier:standard`; blocked by t18125.

### Files Scope

- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-prefetch-fetch.sh`
- `.agents/scripts/pulse-pr-list-cache.sh`
- `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh`
- `.agents/scripts/tests/test-enrich-batch-prefetch.sh`

## Acceptance Criteria

- [ ] A fresh successful cache containing zero issues or PRs returns exit zero and the exact `[]` payload to both prefetch consumers.
- [ ] Fresh empty hits make zero GitHub transport attempts and emit a cache-hit-empty event in t18125 telemetry.
- [ ] Fresh nonempty legacy and versioned snapshots remain compatible and produce unchanged normalized arrays.
- [ ] Missing, stale, malformed, non-array, and failed cache reads never become authoritative empty state; they preserve the existing live fallback and error classification.
- [ ] Concurrent atomic replacement cannot expose a partial file as a valid hit, and retrying a failed read is idempotent.
- [ ] Focused tests, ShellCheck, changed lint, required CI, and a short canary pass before t18127 is promoted.

## Context & Decisions

- Exit status/explicit state is authoritative; array cardinality is data.
- The exact-output PR provider is prior art because it caches successful empty output without changing semantics.
- Schema additions remain backward-compatible and caches stay disposable.

## Relevant Files

- `.agents/scripts/pulse-batch-prefetch-helper.sh:344-430,760-846` — current normalized cache and success/miss exit contract.
- `.agents/scripts/pulse-prefetch-fetch.sh:205-248,339-381` — current `[]` rejection and live fallback.
- `.agents/scripts/pulse-pr-list-cache.sh:69-131` — successful empty exact-output cache reference.
- `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` — conditional cache fixture harness.

## Dependencies

- **Blocked by:** t18125.
- **Blocks:** t18127.
- **External:** None; focused tests use local fixtures.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read/design | 20m | State contract and compatibility |
| Implementation | 40m | Provider and two consumers |
| Tests/canary | 30m | Empty/stale/malformed fixture matrix |
| **Total** | **1.5h** | |
