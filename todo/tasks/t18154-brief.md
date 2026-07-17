<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18154: Repair stale test source paths after helper module splits

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `stale shell test source path module split enrich repo tier` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 0 recent target-file commits / 0 related merged PRs / 0 related open PRs; no in-flight collision found
- [x] File refs verified: 6 source/test ranges checked, all present at `ede5fc810b2ff950a6c6dee5d3ca648cb6f7aff2`
- [x] Tier: `tier:standard` — two mechanical test edits, but `test-pulse-repo-tier.sh` is 534 lines and exceeds the simple-tier file-size limit
- [x] Seeded draft PR decision recorded: skipped — the issue contains exact current-owner paths and focused reproduction commands; no implementation seed is needed

## Origin

- **Created:** 2026-07-17
- **Session:** OpenCode interactive issue #27770 readiness audit
- **Created by:** ai-interactive
- **Parent task:** None
- **Blocked by:** None
- **Conversation context:** Read-only readiness checks for #27770 ran two existing suites and exposed unrelated baseline failures. Both tests still inspect modules that stopped owning the tested functions after prior file splits.

## What

Update two shell test harnesses so their structural assertions and sourced libraries follow the current function owners. Preserve all behavioural assertions, make both suites pass on current `main`, and do not modify production helper behavior.

## Why

`test-enrich-batch-prefetch.sh` currently reports 25/27 because it searches `issue-sync-helper.sh` for calls now located in `issue-sync-helper-enrich.sh`. `test-pulse-repo-tier.sh` sources `pulse-prefetch-fetch.sh`, so `check_repo_tier_skip` and `update_repo_tier_check_timestamp` are undefined after those functions moved to `pulse-prefetch-orchestration.sh`. These false failures obscure real regressions and make the suites unreliable as follow-on verification.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — two test scripts only.
- [ ] **Every target file under 500 lines?** No — `test-pulse-repo-tier.sh` is 534 lines.
- [x] **Exact old/new ownership paths known?** Yes — both current owners and stale references are verified below.
- [x] **No judgment or design decisions?** Yes — retain assertions and point them at current owners.
- [x] **No error handling or fallback logic to design?** Yes — production behavior is unchanged.
- [x] **No cross-package or cross-module production changes?** Yes — test harnesses only.
- [x] **Estimate 1h or less?** Yes — 45 minutes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification:** Neither target path appears in `.agents/configs/self-hosting-files.conf`; normal auto-dispatch applies.

**Selected tier:** `tier:standard`

**Tier rationale:** The edits are mechanical, but one target exceeds the simple-tier 500-line limit. Standard tier avoids a guaranteed taxonomy mismatch while retaining a narrow two-file scope.

## PR Conventions

Leaf task. The implementation PR uses `Resolves #28133`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Exact stale and current paths are verified; a draft would add lifecycle overhead without reducing implementation uncertainty.
- **Status:** `not-created`
- **Freshness evidence:** Memory, commit, PR-collision, file-reference, and baseline-test checks ran against `ede5fc810b2ff950a6c6dee5d3ca648cb6f7aff2`.
- **Verification run:** Baseline only — enrich suite 25/27; repo-tier suite fails because both tier functions are undefined.
- **Stale-assumption warning:** Re-run `rg` for the four function names before editing; if ownership moved again, follow the new defining module rather than the paths recorded here.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/tests/test-enrich-batch-prefetch.sh:83-100` — inspect `cmd_enrich` in its current owner module while retaining the orchestrator check for `_enrich_process_task`.
- `EDIT: .agents/scripts/tests/test-pulse-repo-tier.sh:15-31,220-232,238-523` — source the orchestration owner and rename stale local constants/helper references consistently.

### Complete Write Surface

- **Callers/readers:** The two test scripts read `.agents/scripts/issue-sync-helper-enrich.sh` and `.agents/scripts/pulse-prefetch-orchestration.sh`; no production caller changes.
- **Writers/mutation paths:** N/A for production because both targets are test harnesses; existing writes remain confined to test-local temporary directories and logs in `.agents/scripts/tests/`.
- **Tests/fixtures:** `.agents/scripts/tests/test-enrich-batch-prefetch.sh` and `.agents/scripts/tests/test-pulse-repo-tier.sh` are both the write surface and focused verification.
- **Schemas/config:** N/A because no schema or configuration is read from the stale paths; existing environment-variable fixtures in both test files remain unchanged.
- **Generated/deployed mirrors:** N/A because `.agents/scripts/tests/` runs directly from repository source and has no generated or deployed mirror.
- **Migrations/backfills:** N/A because the task changes test ownership references only and writes no persistent data.
- **Cleanup/rollback paths:** N/A for runtime cleanup because the tests retain their existing traps; reverting the two test-file edits restores the prior assertions without affecting production state.

### Implementation Steps

1. In `test-enrich-batch-prefetch.sh`, keep sourcing the public orchestrator, but point the two `cmd_enrich` structural searches at the module that defines `cmd_enrich`:

```diff
-if grep -q '_enrich_check_rate_limit' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
+if grep -q '_enrich_check_rate_limit' "${TEST_SCRIPTS_DIR}/../issue-sync-helper-enrich.sh"; then
...
-if grep -q '_enrich_prefetch_issues_map' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
+if grep -q '_enrich_prefetch_issues_map' "${TEST_SCRIPTS_DIR}/../issue-sync-helper-enrich.sh"; then
```

2. In `test-pulse-repo-tier.sh`, replace every stale fetch-module reference consistently:

```diff
-PREFETCH_FETCH_SCRIPT="${SCRIPT_DIR}/../pulse-prefetch-fetch.sh"
+PREFETCH_ORCHESTRATION_SCRIPT="${SCRIPT_DIR}/../pulse-prefetch-orchestration.sh"

-_source_prefetch_fetch() {
+_source_prefetch_orchestration() {
...
- source "$PREFETCH_FETCH_SCRIPT" 2>/dev/null || true
+ source "$PREFETCH_ORCHESTRATION_SCRIPT" 2>/dev/null || true
```

Rename all call sites, the final file-existence guard, the skip message, and comments from `pulse-prefetch-fetch.sh` to `pulse-prefetch-orchestration.sh`. Do not duplicate or move either production function.

3. Run both focused suites, ShellCheck, and changed-file lint. If either suite reveals a behavioural failure after ownership references are corrected, stop and report that separate production defect rather than weakening assertions.

### Hazards and Compatibility

- **Concurrency/atomicity:** Tests use process-local temporary directories; changing source paths introduces no shared-state race.
- **Migration/rollback:** No data or runtime migration; the PR is test-only and independently revertible.
- **Mixed-version/backward compatibility:** Tests intentionally follow current `main`; do not add dual-path fallbacks that could hide a future ownership move.
- **Idempotency/retry:** Re-running either suite must produce the same result and clean its existing fixtures normally.
- **Partial failure/recovery:** A failed test leaves no production mutation; preserve existing traps and teardown functions.

### Complexity Impact

- **Target functions:** `_source_prefetch_fetch` rename in `test-pulse-repo-tier.sh`; no production function changes.
- **Current line count:** 10 lines for the source helper; file length 534 lines.
- **Estimated growth:** 0 lines; replacements only.
- **Projected post-change:** 10 lines for the renamed helper.
- **Action required:** None — preserve function size and test structure.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-enrich-batch-prefetch.sh
bash .agents/scripts/tests/test-pulse-repo-tier.sh
shellcheck .agents/scripts/tests/test-enrich-batch-prefetch.sh .agents/scripts/tests/test-pulse-repo-tier.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The first command proves current enrich ownership and all existing batch-prefetch behavior; the second proves tier functions are loaded and retain interval/write semantics; ShellCheck and changed lint cover shell portability and repository gates.
- **Broad verification trigger:** Not required — discovery shows two test-only path updates with no production or shared configuration changes.

### Files Scope

- `.agents/scripts/tests/test-enrich-batch-prefetch.sh`
- `.agents/scripts/tests/test-pulse-repo-tier.sh`

## Acceptance Criteria

- [ ] `test-enrich-batch-prefetch.sh` passes all 27 assertions while still checking both `cmd_enrich` helper calls.
- [ ] `test-pulse-repo-tier.sh` passes without `command not found` and retains every hot/warm/cold interval and timestamp assertion.
- [ ] The implementation diff changes only the two declared test files; no production helper or assertion is removed or weakened.
- [ ] ShellCheck and `.agents/scripts/linters-local.sh --changed` pass.

## Context & Decisions

- Keep this maintenance fix separate from #27770 cache-semantics implementation.
- `issue-sync-helper.sh` remains the correct public source target for `_enrich_process_task`; only the two `cmd_enrich` call-site searches move to `issue-sync-helper-enrich.sh`.
- `check_repo_tier_skip` and `update_repo_tier_check_timestamp` are defined at `pulse-prefetch-orchestration.sh:461` and `pulse-prefetch-orchestration.sh:530`.
- Do not make tests source both old and new modules; fail loudly on future ownership drift.

## Relevant Files

- `.agents/scripts/tests/test-enrich-batch-prefetch.sh:83-100` — two stale structural searches and one still-correct orchestrator search.
- `.agents/scripts/issue-sync-helper-enrich.sh:419-455` — current `cmd_enrich` definition and both helper calls.
- `.agents/scripts/tests/test-pulse-repo-tier.sh:15-31,220-232,238-523` — stale module constant, source helper, call sites, and skip guard.
- `.agents/scripts/pulse-prefetch-orchestration.sh:461-566` — current tier skip/timestamp function definitions.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Reliable use of these suites as regression evidence for later Pulse/cache work.
- **External:** None; all focused tests use local fixtures.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read | 10m | Reconfirm current function owners |
| Implementation | 15m | Two mechanical path/reference updates |
| Verification | 20m | Focused suites, ShellCheck, changed lint |
| **Total** | **45m** | |
