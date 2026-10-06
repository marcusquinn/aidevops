## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session; implementing now)
- **Evidence source:** `~/.aidevops/logs/pulse.log` checkpoint skip lines; issue comments on wpallstars/wp-fix-plugin-does-not-exist-notices#44 and two issues in a private managed repo

## What

A worker draft PR left behind by a `blocked` or stall/timeout release must reach its recovery path
(one attention record, or one automatic exact-head continuation) even though the released
attempt's launcher posts its own closing `DISPATCH_LEASE phase=terminal` comment after the release.

## Why

About 12 `auto-dispatch` + `status:available` issues are held by `WORKER_DRAFT_CHECKPOINT` every
pulse cycle and never progress. The pulse log shows `BLOCKED_CHECKPOINT_ATTENTION_SKIPPED ... has no
current blocked release` 65 times for PR #49 and 46 times for nostr-vpn PR #8, plus
`STALLED_CHECKPOINT_CONTINUATION_SKIPPED ... has no current stall release` for several private-repo drafts.

Cause: on wp-fix #44 the release (`CLAIM_RELEASED reason=blocked`, comment 5963796649) is followed
38 seconds later by the same attempt's `DISPATCH_LEASE phase=terminal` (comment 5963802527) carrying
the same `lease_token` and `attempt_id` as the pre-release `phase=ready` lease. All three evidence
checks treat any later `DISPATCH_LEASE` as new ownership:

- `pr-checkpoint-continuation-helper.sh` `_pcc_blocked_release_evidence` (no later coordination event),
- `_pcc_stall_release_evidence` (newest coordination event must be the stall release),
- `pr_checkpoint_events.py` `successors_valid` (revision-bound approval would also be rejected).

`dispatch-claim-helper.sh` already treats a terminal lease as the end of ownership, and the existing
fixtures omit the closing lease, so tests pass while production stalls.

## Tier

`tier:standard` — one shared predicate in jq and Python, focused fixtures.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pr-checkpoint-continuation-helper.sh:44-54,536-555,632-649` — add a contextual `ownership($c)` predicate: a coordination comment whose only event lines are `DISPATCH_LEASE phase=terminal` with a `lease_token` the same login used in an earlier non-terminal lease is the earlier attempt closing itself, not a successor. Use it in both evidence functions.
- `EDIT: .agents/scripts/pr_checkpoint_events.py:116-127` — skip the released attempt's own terminal lease (runner login, original ready-lease token) in `successors_valid`.
- `EDIT: .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` and `.agents/scripts/tests/test-pr-checkpoint-revision.py` — production-shaped fixtures with the closing lease, plus foreign-token regressions.

### Complete Write Surface

- **Callers/readers:** `pulse-dispatch-dedup-layers.sh` `_dispatch_blocked_checkpoint_attention`, `_dispatch_stalled_checkpoint_continuation`, `_dispatch_revised_checkpoint` (via `dispatch-approved` and `pr-checkpoint-revision.py`).
- **Writers/mutation paths:** no new writes; existing attention comment / continuation launch become reachable.
- **Existing verification/tests:** the two test files above; `tests/test-pulse-stale-pr-continuation.sh`.
- **Schemas/config/mirrors/migrations:** none. **Rollback:** revert.

### Hazards and Compatibility

- **Security:** only a terminal lease whose token was already used by the same login before the release is ignored; claims, prelaunch/ready leases, dispatch comments, releases and terminal leases for unknown tokens still count as ownership, so a new attempt still suppresses recovery.
- **Retry bounds:** stall continuations remain bounded by the stall count since the PR head.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh
python3 .agents/scripts/tests/test-pr-checkpoint-revision.py
bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh
shellcheck .agents/scripts/pr-checkpoint-continuation-helper.sh
```

- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/pr_checkpoint_events.py`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/tests/test-pr-checkpoint-revision.py`

## Acceptance Criteria

- [ ] Positive: blocked release followed by the same attempt's terminal lease posts one attention record.
- [ ] Positive: stall release followed by the same attempt's terminal lease yields stall evidence.
- [ ] Positive: a revision-bound approval validates when the released attempt's terminal lease follows the release.
- [ ] Regression: a later claim, or a terminal lease with a token not seen before the release, still suppresses recovery.
- [ ] All verification commands pass.
