<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `merged_missing_summary MERGE_SUMMARY closeout worker false failure` → 0 hits.
- [x] Discovery pass: `prework-discovery-helper.sh` found no open issue or PR on these files or keywords (2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:standard`. A one-predicate change in a shared lifecycle helper, plus one regression assertion in an existing suite.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** `~/.aidevops/state/objective-evidence.jsonl` holds 28 `worker_merged_missing_summary` attempt outcomes in the 24 h before 2026-11-19T09:50Z. Each is recorded `effective_outcome=failed`, `next_action=narrow_redispatch`, although the worker's exact-head PR merged and closed its issue. They are the largest share of the 49-row `other-failure` family in `worker-activity-helper.sh summary --since 24h`. `pulse-check-report.jq` excludes that family from autofiled findings, so no detector reported it. Public example: PR #38889 (issue #38850, closed as completed). Its comment `6960653803` was created at 20:51:32Z as the worker's `<!-- MERGE_SUMMARY -->`. The deterministic merge closeout rewrote it at 21:22:58Z to `<!-- PULSE_MERGE_CLOSEOUT:PR#38889 -->` with the marker stripped, and the worker attempt was then recorded as failed.

## What

Accept the merge pass's closeout marker as evidence that the PR's MERGE_SUMMARY exists. A merged worker PR whose summary the merge pass already consumed should then resolve as `merged`, not `merged_missing_summary`.

## Why

`_pm_upsert_pr_closing_comment` (`pulse-merge-pr-closeout.sh:253`) rewrites the worker's MERGE_SUMMARY singleton in place, and `pulse-merge.sh:1867` strips the marker. After every deterministic merge, the worker's own post-exit probe `_pr_handoff_has_merge_summary` finds no marker. The probe then returns `merged_missing_summary` and the worker:

- records a false `failed` outcome with `narrow_redispatch`, which feeds failure families, terminal health, failure feedback and next-dispatch prompts;
- retains its claim (`headless-runtime-worker.sh:1867-1871`) instead of releasing it as `worker_complete`;
- for a signal-less exit, is routed to a premature-exit continuation instead of the post-PR handoff gate (`headless-runtime-result.sh:181-186`).

All of these cost worker attempts and metric accuracy on work that is already delivered.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/shared-claim-lifecycle.sh:212-223`. In `_pr_handoff_has_merge_summary`, count a comment whose body contains `<!-- MERGE_SUMMARY -->` or `<!-- PULSE_MERGE_CLOSEOUT:PR#<pr_number> -->`. Use a null-safe `(.body // "")` and cite this issue.
- EDIT: `.agents/scripts/tests/test-worker-output-classification-head-vs-search.sh:174-179`, `:404-429`. Let the `gh` stub print an optional `STUB_COMMENTS_JSON`. Assert that a merged exact-head PR whose only summary comment carries the closeout marker resolves as `merged|332`, and that a closeout marker for a different PR does not count.

### Files Scope

- `.agents/scripts/shared-claim-lifecycle.sh`
- `.agents/scripts/tests/test-worker-output-classification-head-vs-search.sh`

### Reference pattern

- `_pm_select_pr_closeout_comment_id` (`pulse-merge-pr-closeout.sh:91-130`) already treats the two markers as the same singleton.

## Acceptance Criteria

- [ ] `bash .agents/scripts/tests/test-worker-output-classification-head-vs-search.sh` passes, including the new closeout-marker assertions; the existing `merged_missing_summary` case (no summary and no closeout) is unchanged.
- [ ] `bash .agents/scripts/tests/test-worker-output-classification.sh` and `bash .agents/scripts/tests/test-headless-runtime-completion-tests-finish.sh` pass.
- [ ] ShellCheck reports no warnings for the changed shell files.
- [ ] After deploy, new `worker_merged_missing_summary` outcomes in `objective-evidence.jsonl` fall from about 28 per 24 h to near zero, without a matching rise in `merged_checkpoint` for closed issues.
