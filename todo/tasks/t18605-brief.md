## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session), follow-up to t18602 / GH#33839
- **Evidence source:** live issue/PR coordination comments

## What

A worker draft checkpoint PR whose latest trusted release is `CLAIM_RELEASED reason=clean` or `reason=worker_complete` must get a defined next step — exact-head continuation, an actionable attention record, or closure — instead of staying open indefinitely.

## Why

`pr-checkpoint-continuation-helper.sh` only acts on two release shapes:

- `_pcc_blocked_release_evidence` (`:552-571`) requires `reason=blocked`, which produces a `BLOCKED_CHECKPOINT_ATTENTION` record.
- `_pcc_stall_release_evidence` (`:649-666`) requires `_PCC_STALL_RELEASE_PATTERN` (`:40`: `no_activity`, `wall_clock_stale`, `watchdog_kill:*`, `*_stall`, `*timeout*`), which produces stall continuation.

Any other reason is silently skipped. Live cases:

- Draft PR #33605 ("checkpoint: recover dirty worker worktree for #33602", `origin:worker-takeover`) has been open and untouched since 2026-10-04T22:26Z. Issue #33602's latest releases are `reason=clean exit=0` (2026-10-05T16:35Z and 2026-10-06T21:27Z, two different runners), so workers keep running and exiting clean while the checkpoint never advances.
- In another managed repo, a checkpoint draft has been open since 2026-08-09; its issue's latest release is `reason=worker_complete` (2026-09-06).

## Tier

`tier:thinking` — the policy (continue vs. attention vs. close) depends on what `clean`/`worker_complete` mean when a draft checkpoint still exists.

## How (Approach)

### Verify first

1. Trace why a worker exits `clean`/`worker_complete` while a draft checkpoint exists for its issue: does it skip because of the draft, or finish elsewhere without closing the checkpoint? Inspect worker release emission (`rg -n "reason=clean|worker_complete" .agents/scripts`) and the draft-hold path in dispatch.
2. Decide per reason: if the draft holds unique work, treat it like a stall (exact-head continuation, bounded retries); if the work landed elsewhere, close the draft with a pointer; otherwise post one attention record in the `BLOCKED_CHECKPOINT_ATTENTION` shape (never a coordination-event line, grants nothing).

### Files to Modify

- `EDIT: .agents/scripts/pr-checkpoint-continuation-helper.sh:540-700` — add evidence and handling for `clean`/`worker_complete` releases following the existing blocked/stall helpers, reusing `_PCC_JQ_RELEASE_DEFS` and the `ownership` predicate (including the GH#33839 terminal-lease exclusion).
- `EDIT: .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` — cases for clean and worker_complete releases with an open draft.
- `.agents/reference/checkpoint-revision-recovery.md` — document the new branch.

### Files Scope

- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `.agents/reference/checkpoint-revision-recovery.md`

### Verification

```bash
bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh
bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh
shellcheck .agents/scripts/pr-checkpoint-continuation-helper.sh
```

Runtime: after deploy, #33605 receives a continuation, closure or one attention record within a pulse cycle.

- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] An open worker draft whose latest release is `clean` or `worker_complete` gets exactly one defined outcome (continuation, closure or attention record), deduplicated per PR head.
- [ ] Blocked and stall behaviour is unchanged (existing tests pass).
- [ ] #33605 no longer sits without an action after deployment.
