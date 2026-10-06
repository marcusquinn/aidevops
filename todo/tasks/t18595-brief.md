## Origin

- **Created:** 2026-10-06, interactive session (maintainer-approved filing)
- **Evidence source:** live Pulse log `~/.aidevops/logs/pulse.log` and PR #33755 commit/check history

## What

Stop Pulse from repeatedly running the CI-drift `update-branch` rebase on a PR whose
same required checks keep failing on every rebased head. After one drift rebase has
been tried for a given set of failing required contexts, the next cycle must route the
PR to the CI fix-worker (`_route_pr_to_fix_worker ... "ci"`) instead of rebasing again.

## Why

Throughput: a deterministic code failure (static analysis, complexity, lint) cannot be
fixed by merging the base branch, but on a busy repo the base is always ahead
(`behind_by>0`), so `_attempt_pr_ci_rebase_retry` succeeds every cycle, returns 0, and
the caller returns before fix-worker routing. The PR is never repaired by automation.

Observed on PR #33755 (issue #33750), worker commit `2089e6cc97` at 03:14Z:

| Time (UTC) | Event |
|---|---|
| 03:32 | Pulse update-branch → merge commit `f836c8d8ee` |
| 03:55 | Pulse update-branch → `014798459e`; `Qlty Regression Gate` + `Qlty Smell Regression` failed again |
| 04:18 | Pulse update-branch → `0f3124e5ad`; same two required contexts failed again (04:20) |
| 04:34 | Interactive maintainer pushed the actual fix `f1d52de4e4`; merged next cycle |

Pulse log pattern (repeats three times, never followed by a `_dispatch_ci_fix_worker` line):

```text
[pulse-merge] _check_required_checks_has_terminal_failure: 1 terminal failed required context(s) for PR #33755 ... (t3567)
[pulse-merge] PR #33755 in marcusquinn/aidevops: attempting CI-drift rebase via update-branch (t2805)
[pulse-merge] PR #33755 in marcusquinn/aidevops: CI-drift rebase succeeded via update-branch, deferring to next cycle (t2805)
```

Cost: ~80 minutes of blocked merge, three wasted full CI runs, and a human intervention
for a failure the CI fix-worker path (`pulse-merge-feedback-ci-repair.sh`) exists to handle.

## Tier

`tier:standard` — bounded change on the Pulse merge path with a clear reference pattern;
the design decision (per-PR ledger keyed by failing-context signature) is resolved below.

## How (Approach)

### Worker Quick-Start

- Caller: `_pmp_stage_required_checks` in `.agents/scripts/pulse-merge.sh:1570-1602`
  calls `_attempt_pr_ci_rebase_retry` (line 1585); a 0 return skips
  `_route_pr_to_fix_worker` (line 1589).
- Rebase function: `_attempt_pr_ci_rebase_retry` in
  `.agents/scripts/pulse-merge-process.sh:1047-1145` (~99 lines — at the 100-line
  function-complexity gate; do NOT add logic inside it).
- Failing-context classification: `_check_required_checks_has_terminal_failure` in
  `.agents/scripts/pulse-merge-required-checks.sh:1778` (counts terminal failed
  required contexts; extend or add a sibling that emits their sorted names).
- Sub-library sourcing pattern: `.agents/scripts/pulse-merge.sh:302-324`
  (`source "${_PULSE_MERGE_DIR}/pulse-merge-*.sh"`).
- State-dir precedent: `.agents/scripts/pulse-merge-feedback-ci-repair.sh:1191`
  (`AIDEVOPS_HEADLESS_RUNTIME_DIR` default) and `_ci_repair_write_state` at line 520.

### Files to Modify

- `NEW: .agents/scripts/pulse-merge-ci-drift-ledger.sh` — small sourced lib: record and query per-PR drift-rebase attempts.
- `EDIT: .agents/scripts/pulse-merge.sh:300-325` — source the new lib alongside the other `pulse-merge-*.sh` libs.
- `EDIT: .agents/scripts/pulse-merge.sh:1585-1588` — consult the ledger before `_attempt_pr_ci_rebase_retry`; record after a successful rebase.
- `EDIT: .agents/scripts/pulse-merge-required-checks.sh:1778-1850` — expose the sorted names of terminal failed required contexts (new sibling function preferred over growing the existing one).
- `EDIT: .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh` — add focused cases to the existing suite (it already stubs `_attempt_pr_ci_rebase_retry` at line 497); no new harness.

### Complete Write Surface

- **Callers/readers:** only `_pmp_stage_required_checks` (pulse-merge.sh:1585). The review-repair caller at pulse-merge-process.sh:1260 uses strict `review-repair` policy and is out of scope — leave unchanged.
- **Writers/mutation paths:** new ledger file writes only; GitHub writes unchanged (update-branch or existing fix-worker routing).
- **Existing verification/tests:** `test-pulse-merge-ci-repair-routing.sh`, `test-pulse-merge-pr-context.sh`, `test-pulse-merge-update-branch.sh`, `test-pulse-merge-routine-standalone.sh` (asserts the dry-run guard precedes the rebase call — keep it true).
- **Schemas/config:** none required; an env override for the ledger TTL is optional (`PULSE_CI_DRIFT_LEDGER_TTL_S`, default 7 days).
- **Generated/deployed mirrors:** deployed to `~/.aidevops/agents/scripts/` by `setup.sh`; no generated output.
- **Migrations/backfills:** none — absent ledger = current behaviour (one rebase allowed).
- **Cleanup/rollback paths:** prune entries older than TTL on write; deleting the ledger file restores current behaviour.

### Implementation Steps

1. Add a sibling in `pulse-merge-required-checks.sh` that prints the sorted, newline-separated names of terminal failed required contexts for `repo pr [head]`, reusing the data `_check_required_checks_has_terminal_failure` already fetches. Return non-zero when state cannot be classified.
2. Create `pulse-merge-ci-drift-ledger.sh` with two functions (explicit `return 0/1`, `local var="$1"`):

```bash
# Ledger: one line per PR: "<repo>#<pr>\t<signature>\t<prior_head>\t<epoch>"
# signature = sha of sorted failing required context names
_ci_drift_ledger_should_skip() {   # repo pr head signature -> 0 = skip rebase
	# skip when an entry exists for repo#pr with the same signature and
	# prior_head != current head (Pulse already rebased; same contexts still fail)
}
_ci_drift_ledger_record() {        # repo pr prior_head signature
	# replace any line for repo#pr; prune lines older than TTL; atomic write via mktemp+mv
}
```

3. In `_pmp_stage_required_checks`, before the rebase call: compute the signature; if `_ci_drift_ledger_should_skip` returns 0, log
   `[pulse-merge] PR #N in repo: CI-drift rebase already tried for the same failing required contexts (<names>); routing to CI fix-worker`
   and fall through to `_route_pr_to_fix_worker`. After a successful rebase (rc 0), call `_ci_drift_ledger_record` with the pre-rebase head. If the signature cannot be computed, keep current behaviour (fail-open to one rebase).
4. Add focused cases to `test-pulse-merge-ci-repair-routing.sh` (see Acceptance Criteria).
5. `shellcheck` changed files; run the verification commands below.

### Hazards and Compatibility

- **Concurrency/atomicity:** Pulse runs one merge pass per runner at a time; write the ledger via `mktemp` + `mv` in the same dir. Ledger is runner-local, so another runner may still try one rebase — bounded at one per runner per signature, acceptable.
- **Migration/rollback:** absent/empty ledger = existing behaviour; revert is file deletion plus code revert.
- **Mixed-version/backward compatibility:** older runners keep looping; newer runners route to the fix worker. No shared format.
- **Idempotency/retry:** recording replaces the PR's single line; repeated cycles do not grow the file.
- **Partial failure/recovery:** unreadable/corrupt ledger → treat as absent (one rebase allowed), log once.

### Complexity Impact

- **Target function:** `_pmp_stage_required_checks` in `pulse-merge.sh` (33 lines) — growth ~+12 → ~45 lines. None needed.
- **Target function:** `_attempt_pr_ci_rebase_retry` — no change (already ~99/100 lines).
- `pulse-merge.sh` is 2019 lines and `pulse-merge-process.sh` 2419 lines; put new logic in the NEW lib, not in these files.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh
bash .agents/scripts/tests/test-pulse-merge-pr-context.sh
bash .agents/scripts/tests/test-pulse-merge-update-branch.sh
bash .agents/scripts/tests/test-pulse-merge-routine-standalone.sh
shellcheck .agents/scripts/pulse-merge-ci-drift-ledger.sh .agents/scripts/pulse-merge.sh .agents/scripts/pulse-merge-required-checks.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** routing suite proves skip/route and first-rebase regression; pr-context and update-branch suites prove rebase function behaviour unchanged; routine-standalone proves sourcing and dry-run guard ordering.
- **Broad verification trigger:** Not required.

### Recoverability Checkpoint

- [ ] Focused routing suite passes
- [ ] WIP commit before `linters-local.sh --changed`: `wip: ci-drift rebase ledger`

### Scope Boundaries

**Hard boundaries:** do not change `_attempt_pr_ci_rebase_retry` semantics, the strict `review-repair` path, GH#26406 pending-check handling, or fix-worker dispatch internals in `pulse-merge-feedback-ci-repair.sh`.

**AI brief owner:** interactive maintainer session that filed this issue.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-merge-ci-drift-ledger.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/pulse-merge-required-checks.sh`
- `.agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`

## Acceptance Criteria

- [ ] Positive: when a ledger entry for PR N records a prior drift rebase with the same failing required-context signature and the current head differs from the recorded prior head, `_pmp_stage_required_checks` does not call `_attempt_pr_ci_rebase_retry` and does call `_route_pr_to_fix_worker ... "ci"`; the new log line names the failing contexts.
- [ ] Regression: a PR with no ledger entry, or with a different failing-context signature, still gets exactly one drift rebase attempt and the ledger records it.
- [ ] Regression: pending/in-progress required checks still never trigger update-branch or fix-worker routing (GH#26406 behaviour unchanged); `DRY_RUN=1` still returns before any rebase.
- [ ] Unclassifiable check state keeps current behaviour (fail-open to one rebase) and logs the reason.
- [ ] All listed verification commands pass.

## Context & Decisions

- Chosen: signature-keyed per-PR ledger over a blanket "max N rebases" counter — a genuinely new failure after a base change still deserves one drift rebase, and a same-signature repeat is strong evidence the PR's own code is at fault.
- Rejected: classifying failures by check name (e.g. "static analysis never drifts") — base-branch fixes to shared tooling can legitimately cure such failures once.
- Separate observation, out of scope: issue #33761 sat 30 minutes behind a remote runner's `DISPATCH_LEASE phase=prelaunch` that never launched; lease expiry recovered it as designed. File separately only if prelaunch stalls recur.

## Relevant Files

- `.agents/scripts/pulse-merge.sh:1570-1602` — call site
- `.agents/scripts/pulse-merge-process.sh:1030-1145` — rebase function and contract comment
- `.agents/scripts/pulse-merge-required-checks.sh:1778-1850` — required-check classification
- `.agents/scripts/pulse-merge-feedback-ci-repair.sh` — fix-worker path that should receive these PRs
