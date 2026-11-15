## What

Let a checkpoint-continuation worker that hits a concrete, reproducible `code` or `infrastructure` blocker outside its draft's scope file (or reuse) one worker-ready prerequisite issue in the same repository, and hold its own linked issue with `blocked-by:#N` until that prerequisite closes. Add `pr-review-thread-response-scanner.sh route-prerequisite`, modelled on `route-upstream` (t18991).

## Why

Session mining on 2026-11-15 found 37 open issues across managed repositories whose latest checkpoint continuation ended in a `CONTINUATION_BLOCKER_FINDING`: 15 `code`, 13 `infrastructure`, 6 `decision`, 3 unparsed. Each finding's only next action is "for the brief owner", so a human must read the issue and file the fix.

- The continuation prompt forbids issue creation ("Do not create another branch, worktree, issue, or PR"). Workers record this verbatim, for example: "This data-only continuation cannot change generic code or create a separate process issue under its explicit dispatch scope." That worker had named the exact builder file, reproduction and guards to keep.
- The continuation then releases `worker_complete`, which the stall path treats as continuation-eligible. Sampled issues show 1-3 further same-head continuation launches after a finding (including a 1.5h thinking-tier run). Each rediscovers the same blocker and spends a per-PR fuse release.
- Ordinary workers already capture fixable findings with `claim-task-id.sh` (t3006). Only continuation workers are barred, which is why interactive sessions resolve these faster than Pulse.

## How

1. `.agents/scripts/pr-review-thread-response-scanner.sh`: add `cmd_route_prerequisite <repo_slug> <pr_number> <code|infrastructure> <short_reason> <details_file>`.
   - Continuation-only: requires `AIDEVOPS_PR_REPAIR_LINKED_ISSUE`.
   - Refuses capacity-style reasons and upstream-ownership reasons (route-upstream owns those).
   - Deduplicates on marker `aidevops:checkpoint-prerequisite:<repo>#<issue>:<reason>` across all states:
     - open: reuse it;
     - closed: refuse and tell the worker to name it in `mark-blocked` (bounded loop).
   - Creates the issue through `gh-write-helper.sh issue create` with labels `auto-dispatch,tier:standard,bug`, a sanitized finding and back-links.
   - Creates `blocked-by:#N` if missing and adds it to the linked issue.
   - Prints the issue URL.
2. Same file, `_prrts_prompt_header` and `_prrts_write_prompt_file` step 7: permit issue creation only through `route-prerequisite`. Run it before `mark-blocked` for concrete repository code/tooling defects. Skip it for runner-local or transient blockers (quota, rate limit, a secret or login missing on this runner).
3. `.agents/reference/checkpoint-revision-recovery.md`: document the route.

The existing dependency gate (`_dispatch_dedup_dependency_gates` in `pulse-dispatch-core.sh`) runs before the dedup layers that host `dispatch-stalled`, so the label stops same-head re-arms. `_refresh_cleanup_resolved_blocker_labels` in `pulse-dep-graph.sh` removes it when the prerequisite closes. Re-arm windows then apply as today. No new Pulse stage.

Implementation note: the scanner is near the file-size ratchet, so the command lives in the sourced module `pr-review-thread-response-prerequisite.sh`. The prompt functions are in `pr-checkpoint-continuation-helper.sh`.

### Files Scope

- .agents/scripts/pr-review-thread-response-scanner.sh
- .agents/scripts/pr-review-thread-response-prerequisite.sh
- .agents/scripts/pr-checkpoint-continuation-helper.sh
- .agents/reference/checkpoint-revision-recovery.md
- .agents/scripts/tests/test-pr-review-thread-response-scanner.sh
- .agents/scripts/tests/test-pr-review-thread-response-scanner-lifecycle.sh
- .agents/scripts/tests/test-pr-checkpoint-continuation-selfhold.sh
- TODO.md
- todo/tasks/t19039-brief.md

## Acceptance

- `route-prerequisite` creates one issue per repo/issue/reason, reuses an open one, refuses a closed one, and labels the linked issue `blocked-by:#N`.
- The continuation prompt allows exactly this issue path. Runner-local and transient blockers keep the existing `mark-blocked` path.
- Existing scanner tests pass; ShellCheck clean.

## Verification

- `.agents/scripts/tests/test-pr-review-thread-response-scanner.sh` and `test-pr-review-thread-response-scanner-lifecycle.sh`.
- After release, a continuation finding with a repository code blocker produces a linked prerequisite issue and a `blocked-by:#N` label, with no further same-head continuation launches until it closes.

`decision` findings are out of scope here: the AI brief-owner resolver (GH#38155) is only reachable from `blocked` releases and is off by default. Tracked separately.
