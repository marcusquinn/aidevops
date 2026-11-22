## What

A stale `origin:interactive` draft PR handed to the worker pipeline (GH#39158) must actually reach a continuation worker that finishes it and marks it ready. Today the handover only adds `origin:worker-takeover`, and no lane picks the draft up afterwards, so the PR and its pulse tracking issue stay parked indefinitely.

## Why

Observed on this repository after v3.39.264 (GH#39873) fixed tracking-issue linkage: draft PRs #37733 and #35518 carry `origin:interactive` + `origin:worker-takeover`, `Resolves #39888` / `Resolves #39889`, green or unknown CI, and a `<!-- pulse-interactive-handover -->` comment from 2026-11-22T17:30Z. Their tracking issues #39888/#39889 sit at bare `status:blocked`; the label normalizer then added `needs-ai-recovery`. pulse.log shows only repeated `draft PR not eligible for auto-merge (GH#23525)` skips.

Root cause — every downstream lane still treats the handed-over draft as human-owned:

1. Merge pass skips drafts (correct; readiness belongs to a worker).
2. Feedback routing only fires on failing CI/conflicts/review, so a green draft never routes.
3. `pr-checkpoint-target-lib.sh` `checkpoint_protected` and `_pr_checkpoint_pr_metadata_is_eligible`, and `dispatch-dedup-pr.sh` `_ddpr_classify_sibling_drafts` `dedup_protected`, list `origin:interactive` as protective even when `origin:worker-takeover` is present. Feedback routing (`_feedback_route_labels_block_routing`) already lets takeover override interactive provenance; these predicates do not, so dispatch dedup reports a protected durable block and checkpoint continuation rejects the PR.
4. `_recover_interactive_pr_work_issue` (`pulse-merge-process.sh`) creates the tracking issue as bare `status:blocked`, promising that "existing feedback routing transitions this issue to available". No code performs that transition for a draft whose linkage is verified, and the issue lacks `auto-dispatch`, so `_pr_checkpoint_issue_metadata_is_eligible` treats its `origin:interactive` as a hold.
5. `pr-checkpoint-continuation-helper.sh dispatch-stalled` admits a draft only with worker stall-release or expired-claim evidence. A handed-over interactive draft has no worker history, so even a corrected predicate would find no admission evidence.

GH#39158's own How said "a worker continues the branch, finishes the remaining work, and marks it ready", but its acceptance only checked for a handover log line.

## How

- `.agents/scripts/pr-checkpoint-target-lib.sh`: `origin:interactive` is protective only without `origin:worker-takeover` in `checkpoint_protected` and `_pr_checkpoint_pr_metadata_is_eligible`. Every other protective label (`hold-for-review`, `no-takeover`, `no-auto-dispatch`, `needs-maintainer-review`, `persistent`) is unchanged.
- `.agents/scripts/dispatch-dedup-pr.sh` `_ddpr_classify_sibling_drafts`: the same takeover rule for `dedup_protected`, so the draft is the issue's `WORKER_DRAFT_CHECKPOINT` and routes to continuation.
- `.agents/scripts/pulse-merge-author-checks.sh` `_interactive_draft_pr_try_handover`: once takeover is confirmed (including drafts already handed over), release the PR's verified closing-link pulse tracking issue (marker `pulse-interactive-tracking:<pr>`, collaborator author, open, unassigned, `status:blocked` as its only status, no human hold) to `status:available` + `auto-dispatch`, dropping the blocked-owned `needs-ai-recovery` companion.
- `.agents/scripts/pr-checkpoint-continuation-helper.sh` `_pcc_dispatch_stalled`: after the expired-recovery fallback, admit a handed-over interactive draft once per handover. Evidence: PR carries `origin:interactive` + `origin:worker-takeover`, a trusted unedited `<!-- pulse-interactive-handover -->` PR comment no older than the head commit, and no trusted coordination event on the issue after that comment. Later attempts use the existing release/fuse/attention logic.
- Update the GH#39158 doc comment and the tracking-issue body text to describe the real route.

### Files Scope

- `.agents/scripts/pr-checkpoint-target-lib.sh`
- `.agents/scripts/dispatch-dedup-pr.sh`
- `.agents/scripts/pulse-merge-author-checks.sh`
- `.agents/scripts/pulse-merge-process.sh`
- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/tests/test-pulse-merge-interactive-handover.sh`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`

## Acceptance

- An interactive draft with `origin:worker-takeover`, a trusted handover comment newer than its head and an unassigned released tracking issue is admitted by `dispatch-stalled` once; a second call after a coordination event is not admitted through the handover route.
- The same draft without `origin:worker-takeover`, or with `no-takeover`/`hold-for-review`, stays protected in dedup and checkpoint predicates.
- A handover comment older than the head commit (the human pushed after handover) is not admission evidence.
- The tracking-issue release happens only for the pulse tracking marker issue linked by the PR's closing reference; other issues and held issues are untouched.
- After deploy, #39888/#39889 move to `status:available` + `auto-dispatch`, and pulse.log shows a `STALE_PR_CONTINUATION ... reason=interactive_handover` line for #37733/#35518.

## Verification

- `shellcheck` on the changed scripts.
- `bash .agents/scripts/tests/test-pulse-merge-interactive-handover.sh`
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh`
- `bash .agents/scripts/tests/test-pulse-merge-origin-interactive-auto-merge.sh`

Ref #39888, Ref #39889, Ref #39158, Ref #39873
