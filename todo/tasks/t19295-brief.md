## What

Checkpoint continuation must prove that this runner can start a model before it posts a `DISPATCH_CLAIM`, and a never-launched release must publish its cause class. Today a runner with no usable model (for example, every OAuth account out of allowance or backed off) claims the draft, fails before launch, and posts a bare `CLAIM_RELEASED reason=worker_not_launched`. Nobody can tell from GitHub why it failed.

## Why

Observed 2026-11-22 on #39888/#39889 (drafts #37733/#35518): runner alex-solovyev claimed each draft twice, at 22:35Z and 23:35Z. Each time it released `worker_not_launched` 15–25s after the claim, with no ready lease. A second runner launched both drafts at 23:40Z. All recent `worker_not_launched` releases in this repo come from that runner (also #39904, #39854, #39885). A runner that is out of AI allowance would produce exactly this pattern, but the public record cannot confirm it.

Root cause, from the code:

1. The ordinary issue path checks the canary before it claims: `pulse-dispatch-worker-gates.sh` `_dlw_canary_preflight` / `_dlw_claim_lock_after_canary` (t3549). Exit 75 means every candidate model is backed off, and 78 means none is configured; in both cases no claim is posted. The checkpoint continuation path (`pr-checkpoint-continuation-helper.sh` `_pcc_dispatch` → `_pcc_claim_checkpoint`) has no equivalent: no `pr-*.sh` script runs the canary or `choose_model` before claiming.
2. `headless-runtime-run.sh` `_select_cmd_run_model` records `model_selection_failed`, and `headless-runtime-worker-finish.sh` `_hrw_finish_not_launched` logs `cause=${_WORKER_PRELAUNCH_FAILURE_REASON}` locally. The public release built by `_hrw_release_dispatch_claim` / `pr-checkpoint-compensation.sh` `_pcc_release_not_launched_claim` drops the cause.

GH#39913 (PR #39917) and GH#39920 (PR #39923) already bound the damage after the fact by fencing a runner per head. This task stops the claim from happening at all and makes the cause visible.

## How

- `.agents/scripts/pr-checkpoint-continuation-helper.sh` `_pcc_dispatch`: before `_pcc_claim_checkpoint`, run the same model-availability/canary preflight as `_dlw_canary_preflight`, using the continuation's tier (including `PCC_ESCALATION_TIER`). On rc 75/78, print `STALLED_CHECKPOINT_CONTINUATION_SKIPPED: ... reason=model_unavailable` and return without claiming. Reuse the existing helper and do not duplicate the gate logic; if the gate function needs extracting into a shared lib, extract it.
- `.agents/scripts/headless-runtime-worker-finish.sh` `_hrw_finish_not_launched`, and `.agents/scripts/pr-checkpoint-compensation.sh` `_pcc_release_not_launched_claim`: append `cause=<class>` to the public `CLAIM_RELEASED reason=worker_not_launched` line. Use only the fixed internal enum values (`model_selection_failed`, `worker_signing_unavailable`, `worker_runtime_cli_missing`, …), never paths or free text. Readers of `reason=worker_not_launched` (`_PCC_JQ_LAUNCH_DEFS` `not_launched_release`) match on `(^| )reason=worker_not_launched( |$)`, so an extra field is compatible; verify this.
- Exact call sites inside `_pcc_dispatch` may need discovery; the claim is posted from `_pcc_claim_checkpoint` (dispatch-claim-helper.sh).

### Files Scope

- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/pulse-dispatch-worker-gates.sh`
- `.agents/scripts/headless-runtime-worker-finish.sh`
- `.agents/scripts/pr-checkpoint-compensation.sh`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`

## Acceptance

- With every candidate model backed off (canary rc 75), `dispatch-stalled` posts no `DISPATCH_CLAIM` and logs `reason=model_unavailable`.
- A never-launched release publishes `cause=<enum>`, and the existing never-launched episode logic (GH#38358/GH#39913/GH#39920) still classifies it as never-launched.
- A healthy runner's continuation path is unchanged.

## Verification

- `shellcheck` on the changed scripts.
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-attention.sh`
- `bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh`

Ref #39888, Ref #39889, Ref #39913, Ref #39920
