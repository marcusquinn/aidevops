## What

A handed-over interactive draft whose first continuation never launched must get the same one bounded retry that worker drafts get. Today the GH#39908 handover admission is consumed by a failed launch, and the draft is parked again with no admission route.

## Why

Observed after GH#39908 (PR #39914) deployed: runner alex-solovyev released #39888/#39889 to `status:available` + `auto-dispatch` at 2026-11-22T22:30Z, admitted PR #37733/#35518 through the interactive-handover route, posted `DISPATCH_CLAIM` + `DISPATCH_LEASE phase=prelaunch` in session `pr-checkpoint-continuation-marcusquinn-aidevops-<pr>`, then `CLAIM_RELEASED reason=worker_not_launched` 15-25s later. No worker ever ran.

Root cause: `_pcc_interactive_handover_evidence` (`.agents/scripts/pr-checkpoint-continuation-helper.sh`) rejects any trusted coordination comment at or after the handover. The stall-release route treats a never-launched episode in the continuation's own session as transparent (GH#38358, `_PCC_JQ_LAUNCH_DEFS` `unlaunched_episode`) and allows one bounded retry. The handover route does not, so `_pcc_stall_release_evidence` finds no release (the episode is transparent), `_pcc_dispatch_interactive_handover_draft` finds the evidence consumed, and every runner logs `STALLED_CHECKPOINT_CONTINUATION_SKIPPED` forever.

## How

- `.agents/scripts/pr-checkpoint-continuation-helper.sh` `_pcc_interactive_handover_evidence`: take the continuation session key; ignore coordination comments after the handover that belong to a never-launched episode of that session (reuse `_PCC_JQ_LAUNCH_DEFS` `unlaunched_episode`). Admit while fewer than 2 such episodes exist (the original attempt plus one retry, matching the stall route's `$failed_launches - 1` allowance); refuse after that, and refuse on any launched episode or other coordination.
- `_pcc_dispatch_interactive_handover_draft`: pass `_pcc_session_key "$repo" "$pr"`, report the retry count in the `STALE_PR_CONTINUATION` line, and print a distinct skip reason when relaunch retries are exhausted.

### Files Scope

- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`

## Acceptance

- After a handover and one never-launched episode in the continuation session, `dispatch-stalled` admits the draft again through the handover route.
- After two never-launched episodes, the handover route refuses and logs that retries are exhausted.
- A launched episode (ready lease or `Dispatching worker`) or any coordination outside the continuation session still consumes the handover evidence.
- After deploy, #37733/#35518 get a second continuation attempt.

## Verification

- `shellcheck .agents/scripts/pr-checkpoint-continuation-helper.sh`
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`

Ref #39908, Ref #39888, Ref #39889
