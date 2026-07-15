<!-- aidevops:brief-schema=v2 -->

# t18134: Eliminate jq E2BIG in objective reconciliation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `27803 jq E2BIG objective reconciliation` → 0 hits — no relevant stored lessons
- [x] Discovery pass: 0 relevant commits / 0 relevant merged PRs / 0 relevant open PRs supersede the cited call site
- [x] File refs verified: 5 refs checked against current `origin/main`, all present
- [x] Tier: `tier:standard` — two files, but large-input transport and regression-guard design require judgment
- [x] Seeded draft PR decision recorded: skipped — the existing large-JSON test supplies the implementation pattern

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive review and auto-dispatch handoff
- **Created by:** AI DevOps (ai-interactive), directed and cryptographically approved by the maintainer
- **Parent task:** None; leaf task for GH#27803
- **Blocked by:** None
- **Conversation context:** Review reproduced OS error 7 for oversized argv and confirmed that the issue's literal `jq -n '{issues:.}'` replacement would emit `null`, so the brief records a safe multi-input transport pattern.

## What

Move `issues_json` and `objective_prs` off jq argv in objective reconciliation while producing the exact existing `{issues, prs, merged_lookup}` shape. Extend the established large-JSON regression suite so this call site and equivalent known-large variables cannot regress to `--argjson` transport.

## Why

Issue bodies can push the issues array beyond Linux `MAX_ARG_STRLEN`, preventing jq from starting and silently skipping objective-ledger reconciliation. This is a recurring anti-pattern previously fixed in prefetch and quality paths.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The code change is small, but both large arrays, jq input semantics, cleanup/error paths, and the recurrence guard must be coordinated.

## PR Conventions

Leaf task: title the implementation PR `t18134: ...` and use `Resolves #27803`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** `.agents/scripts/tests/test-jq-large-json-argv-regression.sh` already provides the authoritative fixture and pattern.
- **Status:** `not-created`
- **Freshness evidence:** Current source and large-JSON regression suite checked on 2026-07-15.
- **Verification run:** Planning readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check the objective block if t18103 follow-up work moves it before dispatch.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-issue-reconcile.sh:1372-1389` — construct objective input without large argv values.
- `EDIT: .agents/scripts/tests/test-jq-large-json-argv-regression.sh:48-76,162-185` — exercise objective payload construction above 131,072 bytes and guard the source pattern.

### Complete Write Surface

- **Callers/readers:** `reconcile_issues_single_pass` builds the payload; `.agents/scripts/objective-reconciliation-helper.sh reconcile` reads it from stdin.
- **Writers/mutation paths:** The objective block is the sole producer of `{issues, prs, merged_lookup}` for this call; issue and PR arrays come from prefetch cache/API paths.
- **Tests/fixtures:** `.agents/scripts/tests/test-jq-large-json-argv-regression.sh` already builds 600-item issue/PR arrays and scans known-large argv patterns.
- **Schemas/config:** N/A because scoped searches found no external schema/config; preserve the existing JSON keys and array types exactly.
- **Generated/deployed mirrors:** `setup.sh` deploys scripts; no generated source file is edited.
- **Migrations/backfills:** N/A because no persisted schema changes; ledger reconciliation remains idempotent and repairs on the next cycle.
- **Cleanup/rollback paths:** N/A because the selected two-document stdin stream creates no files or persistent state; rollback is a git revert.

### Implementation Steps

1. Use a two-document stdin stream that consumes both arrays explicitly. Do not pass either array through `--argjson`; the temp-file plus `--slurpfile` pattern at `.agents/scripts/pulse-prefetch-infra.sh:261-284` remains fallback reference only if a verified platform incompatibility blocks streaming.

```bash
# Safe selected shape: two JSON documents enter jq through stdin.
objective_input=$(printf '%s\n%s\n' "$issues_json" "$objective_prs" |
	jq -sc --arg merged "$oimp_lookup" \
	'{issues: .[0], prs: .[1], merged_lookup: $merged}') || objective_input=""
```

2. Preserve fail-open behavior: malformed input leaves `objective_input` empty and skips the helper without terminating the pulse pass.
3. Add a test using the existing `LARGE_ISSUES_JSON`/`LARGE_PRS_JSON` fixtures that asserts both 600-item arrays and `merged_lookup` survive exactly.
4. Extend `test_known_large_argjson_patterns_absent` to reject `--argjson issues "$issues_json"` and `--argjson prs "$objective_prs"` in `pulse-issue-reconcile.sh`.

### Hazards and Compatibility

- **Concurrency/atomicity:** Construction is a process-local stdin pipeline with no shared files or state.
- **Migration/rollback:** No migration; revert restores the previous producer and next-cycle repair remains available.
- **Mixed-version/backward compatibility:** Output schema is byte-semantically equivalent JSON even if formatting changes.
- **Idempotency/retry:** Failed construction skips one cycle; the next cycle rebuilds the same repo slice.
- **Partial failure/recovery:** Never call the objective helper with `issues:null`, truncated arrays, or one missing document.

### Complexity Impact

- **Target function:** `reconcile_issues_single_pass` in `.agents/scripts/pulse-issue-reconcile.sh`.
- **Current line count:** Existing large orchestrator; do not add nested cleanup branches inline.
- **Estimated growth:** Net 0-20 lines.
- **Projected post-change:** Avoid increasing function complexity by extracting a small payload builder if temp-file cleanup needs multiple branches.
- **Action required:** Prefer a compact streaming replacement or focused helper.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-jq-large-json-argv-regression.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
shellcheck .agents/scripts/pulse-issue-reconcile.sh .agents/scripts/tests/test-jq-large-json-argv-regression.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Large-JSON test proves transport and source guard; reconcile suite protects orchestration behavior; ShellCheck/lint cover shell semantics.
- **Broad verification trigger:** Not required unless the implementation introduces a shared jq transport helper used by other modules.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-jq-large-json-argv-regression.sh`
- [ ] WIP commit created before broad gates: `wip: remove objective JSON from argv`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/pulse-issue-reconcile.sh`
- `.agents/scripts/tests/test-jq-large-json-argv-regression.sh`

## Acceptance Criteria

- [ ] Objective reconciliation accepts issue and PR arrays individually larger than 131,072 bytes and preserves both complete arrays plus `merged_lookup`.
- [ ] The implementation contains no known-large `issues_json` or `objective_prs` value passed through jq argv.
- [ ] Malformed/failed construction remains fail-open for the pulse cycle and never sends `null`/partial objective data.
- [ ] Focused tests, ShellCheck, and changed-file lint pass.

## Context & Decisions

- The issue's proposed `jq -n '{issues:.}'` form is explicitly rejected because `.` is `null` under `-n` without `input`.
- Both potentially large arrays move off argv, not only the array that first triggered E2BIG.
- Extend the existing deterministic regression suite rather than creating another one-off test.

## Relevant Files

- `.agents/scripts/pulse-issue-reconcile.sh:1323-1334` — issue array producers.
- `.agents/scripts/pulse-issue-reconcile.sh:1372-1389` — affected objective producer/consumer chain.
- `.agents/scripts/pulse-prefetch-infra.sh:261-284` — established temp-file/`--slurpfile` pattern.
- `.agents/scripts/tests/test-jq-large-json-argv-regression.sh:48-76` — existing >128KB fixtures.
- `.agents/scripts/tests/test-jq-large-json-argv-regression.sh:162-185` — recurrence guard and test runner.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Reliable objective-ledger repair on repositories with large issue bodies.
- **External:** Python 3 is already an existing test dependency; no credentials or services.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Confirm consumer schema and established transport pattern |
| Implementation | 35m | Replace producer and preserve failure semantics |
| Testing | 40m | Large fixture, reconcile suite, lint |
| **Total** | **1.5h** | |
