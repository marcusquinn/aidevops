## Origin

Interactive session (productivity mission, 2026-11-15). The GH#38353 / t19007 external-trigger revisit has never finished a pass in production, so `external_trigger_pending` holds are never revisited and their drafts wait for a human retry.

Evidence from `~/.aidevops/logs/pulse.log`:

```text
[pulse-wrapper] Stage start: trigger_revisit (timeout 12s)
[lifecycle] worker_killed pid=... reason=stage_timeout_12s trigger_age=14s session=trigger_revisit
[pulse-wrapper] Async post-dispatch housekeeping: trigger_revisit incomplete (rc=124, deferred=0) — not recorded as complete
```

That is 5 of 5 runs since deploy, with no `TRIGGER_REVISIT` outcome line ever logged. One managed repository alone has 36 open issues whose comments contain `Terminal blocker: reason=external_trigger_pending` (one owner-scoped search), including drafts idle since 2026-11-07.

Two causes:

1. **Cheap slice.** `_pulse_run_post_dispatch_housekeeping_stages` (`.agents/scripts/pulse-dispatch-engine-housekeeping.sh`) runs `trigger_revisit` with the 12s scanner slice (`stage_timeout`). The helper's own budget defaults to 240s, and each AI decision allows 60s. GH#38204 fixed the same failure for `post_merge_scanner` by moving it to `heavy_timeout` (72s).
2. **One GitHub search per repository.** `tbtr_run` → `_tbtr_repo` runs `_tbtr_authority` plus one `search/issues` query for each of the 69 maintainer-role pulse repositories. The search API allows 30 requests/minute, so no stage budget can complete a pass. The repositories belong to only 4 owners. Multiple `user:` qualifiers OR together (verified: `user:A user:B` returned A's 36 + B's 0 = 36), and `terminal_blocker_search_issue_refs` already returns `slug\tnumber\tupdated` per hit.

## What

1. Run `trigger_revisit` with `heavy_timeout`. Pass the stage ceiling to the helper, so its wall-clock budget (`AIDEVOPS_TRIGGER_REVISIT_BUDGET_S`, explicit value still honoured when smaller) ends before the stage kill. The pass then exits cleanly and is recorded complete, with per-issue records persisted.
2. Search once per owner (`user:<owner>`), not once per repository. Keep only hits whose slug is in the requested set, and probe authority only for repositories with hits.
3. Clamp each AI decision to the remaining deadline, and skip AI (record `scheduled`, no inference) when too little time remains, so a single inference cannot outlive the pass.

## Tier

`tier:standard`. Two shell scripts plus existing hermetic tests.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-engine-housekeeping.sh`: `trigger_revisit` uses `"$heavy_timeout"`; `_run_terminal_blocker_trigger_revisit` takes the stage timeout and exports the clamped budget for the helper invocation only.
- `EDIT: .agents/scripts/terminal-blocker-trigger-revisit.sh`: `tbtr_run` groups slugs by owner and issues one search per owner; `_tbtr_repo` consumes pre-fetched refs; `_tbtr_decide` timeout is `min(60, remaining - margin)`; AI is disallowed below a minimum remaining time.
- `EDIT: .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh`: assert `optional:trigger_revisit:72` next to the GH#38204 post-merge assertion.
- `EDIT: .agents/scripts/tests/test-terminal-blocker-circuit.sh`: in `_trigger_revisit_cases`, assert one search per owner across several same-owner repositories, filtering of foreign slugs, and no AI call when the deadline is near.

### Files Scope

- `.agents/scripts/pulse-dispatch-engine-housekeeping.sh`
- `.agents/scripts/terminal-blocker-trigger-revisit.sh`
- `.agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`

## Acceptance Criteria

- [ ] `trigger_revisit` runs with the heavy housekeeping timeout, and the helper's budget is below that timeout.
- [ ] A pass over N repositories under K owners issues K searches, not N; hits for slugs outside the requested set are ignored.
- [ ] No AI decision starts when less than the minimum remaining time is left; started decisions are bounded by the remaining deadline.
- [ ] After deploy, `pulse.log` shows `TRIGGER_REVISIT repo=... decision=...` lines and `trigger_revisit` no longer logs `Stage timeout`.
- [ ] Tests pass and ShellCheck is clean:

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-terminal-blocker-circuit.sh && bash .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh && shellcheck .agents/scripts/terminal-blocker-trigger-revisit.sh .agents/scripts/pulse-dispatch-engine-housekeeping.sh"
  ```

## Context & Decisions

- No rotation cursor: per-owner search makes the read cost O(owners). Per-issue records already make unchanged, not-yet-due holds free on later passes.
- Revisit classes, authority checks, the OWNER/MEMBER retry rule and the decision allowlist are unchanged. `permission_required` and `source_access_blocked` keep their human-owned flows.
- `pr_review_thread_response` (19/35 timeouts at 12s) and `dedup_cleanup` (15/34) also hit the cheap slice, but they rotate with a cursor (t18944), so they progress. They are out of scope.
