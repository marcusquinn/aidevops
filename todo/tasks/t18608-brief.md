## Task


When a worker records its own first non-rate-limit failure for an issue through `_report_failure_to_fast_fail`, the fast-fail entry must get `enrichment_needed=true` for enrichment-relevant reasons. This matches the pulse-side `fast_fail_record` behaviour. The pulse enrichment pre-pass then analyses these issues.

## Done when

- [ ] A first worker-side failure with an allow-listed reason sets `enrichment_needed=true` in the fast-fail state.
- [ ] The worker-side writer carries the enrichment flag.
- [ ] Negative: `worker_post_pr_handoff_unverified` never sets the flag, and an entry with `enrichment_done=true` is never re-flagged (covered by the new test case).
- [ ] `shellcheck` is clean; the existing fast-fail tests pass.

<details>
<summary>Worker implementation contract</summary>

## Worker Guidance


### Files to Modify

- `EDIT: .agents/scripts/headless-runtime-failure.sh:1668-1720` — `_fast_fail_write_state`: accept an optional 10th argument `set_enrichment` (`true|false`, default `false`). When `true`, add `| .[$k].enrichment_needed = true` to the jq program, but only if `.[$k].enrichment_done != true`.
- `EDIT: .agents/scripts/headless-runtime-failure.sh:1807-1815` — in `_report_failure_to_fast_fail`, compute `set_enrichment=true` when `new_count -eq 1` and the reason is in the allow-list; pass it through.
- `EDIT: .agents/scripts/tests/test-headless-runtime-failure-classification.sh` — add one focused case covering the flag set and not set.

Allow-list (decided):

- **flag:** `worker_noop_zero_output`, `watchdog_stall_killed`, `worker_failed`, `premature_exit`, `stale_timeout`;
- **do not flag:** `worker_post_pr_handoff_unverified` and the closed-unmerged reason. A PR exists there, so the problem is review or handoff, not missing guidance.

### Complete Write Surface

- **Callers/readers:** reader `dispatch_enrichment_workers` (`.agents/scripts/pulse-quality-debt.sh:423`, jq `select(.value.enrichment_needed == true)`). Writers: the 4 callers above in `headless-runtime-worker.sh`.
- **Writers/mutation paths:** `_fast_fail_write_state` (headless) and `_fast_fail_record_locked` / `_ff_mark_enrichment_done` (`pulse-fast-fail.sh:595`, `:976`) share `fast-fail-counter.json` under the same lockdir.
- **Existing verification/tests:** `.agents/scripts/tests/test-headless-runtime-failure-classification.sh`, `.agents/scripts/tests/test-fast-fail-release-retry-reset.sh`, `.agents/scripts/tests/test-worker-outcome-routing.sh`.
- **Schemas/config:** `fast-fail-counter.json` entry gains the existing optional key `enrichment_needed`. No new keys.
- **Generated/deployed mirrors:** deployed `~/.aidevops/agents/scripts/` via `setup.sh`.
- **Migrations/backfills:** none. Existing unflagged entries age out (`FAST_FAIL_EXPIRY_SECS`).
- **Cleanup/rollback paths:** `_ff_mark_enrichment_done` clears the flag. Revert the PR to roll back.

### Implementation Steps

1. Extend `_fast_fail_write_state` with the optional argument and the jq clause guarded by `enrichment_done`.
2. Add a small helper `_fast_fail_reason_wants_enrichment` (case statement, explicit `return 0/1`) to keep `_report_failure_to_fast_fail` from growing.
3. Pass the flag from `_report_failure_to_fast_fail`.
4. Add a test case: a first `worker_noop_zero_output` sets `enrichment_needed=true`; a first `worker_post_pr_handoff_unverified` does not; a second failure does not re-set the flag after `enrichment_done=true`.
5. Run `shellcheck` and the tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** the write already happens under `_fast_fail_acquire_lock` (line 1792). The single jq pass keeps the change atomic.
- **Migration/rollback:** code-only.
- **Mixed-version/backward compatibility:** an older pulse ignores nothing new; the key is already consumed.
- **Idempotency/retry:** the `enrichment_done` guard prevents re-enrichment loops.
- **Partial failure/recovery:** a jq failure keeps the existing error path (line 1696-1699).

### Complexity Impact

- **Target function:** `_report_failure_to_fast_fail` in `.agents/scripts/headless-runtime-failure.sh`
- **Current line count:** 87 lines (threshold: 100)
- **Estimated growth:** +3 lines (logic lives in a new helper)
- **Projected post-change:** ~90 lines (90%)
- **Action required:** Watch. Keep the decision logic in `_fast_fail_reason_wants_enrichment`. Do not inline it.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-headless-runtime-failure-classification.sh
bash .agents/scripts/tests/test-fast-fail-release-retry-reset.sh
shellcheck .agents/scripts/headless-runtime-failure.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the classification test proves the flag behaviour. The retry-reset test proves that the existing state shape is unchanged.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change the pulse-side `_fast_fail_record_locked` semantics or the rate-limit path (the worker deliberately skips fast-fail for transient API conditions, `headless-runtime-worker.sh:2092`).

**AI brief owner:** interactive maintainer session that filed this issue.

**Recovery:** preserve the current PR and use the structured runtime request in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/tests/test-headless-runtime-failure-classification.sh`

</details>

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

<!-- aidevops:brief-schema=v2 -->


## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse enrichment` → 0 hits — no relevant lessons
- [x] Discovery pass: 10 recent commits touch the target files (none about enrichment flags) / 0 merged PRs on this behaviour / 0 open related PRs
- [x] File refs verified: 7 refs checked, all present at HEAD `90631c51d`
- [x] Tier: `tier:standard` — known pattern; the reason allow-list is decided in this brief
- [x] Seeded draft PR decision recorded: skipped — small change, the issue body is sufficient

## Origin

- **Created:** 2026-10-07
- **Session:** opencode:unknown-2026-10-07
- **Created by:** ai-interactive
- **Conversation context:** While investigating why pulse enrichment never helps, it emerged that most worker failures never enter the enrichment queue at all.

## What

When a worker records its own first non-rate-limit failure for an issue through `_report_failure_to_fast_fail`, the fast-fail entry must get `enrichment_needed=true` for enrichment-relevant reasons. This matches the pulse-side `fast_fail_record` behaviour. The pulse enrichment pre-pass then analyses these issues.

## Why

Only one writer sets the flag: the pulse-side `_fast_fail_record_locked` (`.agents/scripts/pulse-fast-fail.sh:665-672`, when `new_count == 1`). The worker-side writer `_report_failure_to_fast_fail` (`.agents/scripts/headless-runtime-failure.sh:1745-1831`) uses `_fast_fail_write_state` (line 1668), which only merges `count/ts/reason/...`.

Worker-side callers in `.agents/scripts/headless-runtime-worker.sh`:

- line 2081: generic `worker_failed` / run failure reason;
- line 2360: `worker_post_pr_handoff_unverified`;
- line 2408: `worker_noop_zero_output`;
- line 2443: closed-unmerged.

Runtime evidence from a live `fast-fail-counter.json` (25 entries):

- all 13 entries with `enrichment_done=true` have pulse-side reasons (`stale_timeout`, `premature_exit`);
- all 12 entries with worker-side reasons (`worker_noop_zero_output` ×5, `watchdog_stall_killed` ×3, `worker_post_pr_handoff_unverified` ×4) have `enrichment_needed` absent. 11 of them have count=1 and one has count=2.

Because the merge is additive, the flag would have persisted if any writer had set it. So these failures were never queued for enrichment.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeleton only.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?** The allow-list is decided below.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?** The lock already exists.
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** `headless-runtime-failure.sh` is not listed in `self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** Known pattern copied from `pulse-fast-fail.sh:665-672` into a sibling writer. The worker still writes the code.

## PR Conventions

Leaf task: the PR body uses a closing keyword for this issue.

## Context & Decisions

- Calling the pulse-side `fast_fail_record` from the worker was ruled out: the worker process does not source `pulse-fast-fail.sh`, and the two writers intentionally share only the lock and the file.
- Post-PR handoff failures are excluded because the enrichment prompt targets "how to implement", not PR review state.

## Relevant Files

- `.agents/scripts/pulse-fast-fail.sh:665` — reference: pulse-side flag logic
- `.agents/scripts/headless-runtime-failure.sh:1668` — `_fast_fail_write_state`
- `.agents/scripts/headless-runtime-failure.sh:1745` — `_report_failure_to_fast_fail`

## Dependencies

- **Blocked by:** none. This is independent, but the value is realised once the enrichment worker can launch (sibling task).
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | two writers |
| Implementation | 45m | helper, jq clause, test case |
| Verification | 15m | tests and shellcheck |
| **Total** | **1h15m** | |

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.23 plugin for [OpenCode](https://opencode.ai) v1.18.34 with claude-opus-5-5 spent 1h 57m and 31,228 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVj0-wQ",
  "title": "t18608: fix(fast-fail): worker-side failures never flag enrichment_needed",
  "updatedAt": "2026-10-09T03:00:51Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/33878",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18608",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "33878",
  "captured_at": "2026-10-09T21:16:11Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
