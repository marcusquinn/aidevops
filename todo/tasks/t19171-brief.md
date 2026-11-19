# fix(dispatch): zero-output hold ignores later trusted worker progress and keeps a released issue held for up to 12h

## Origin

Interactive productivity mission session, 2026-11-19. The CI-feedback redispatch of #39222 (after its PR #39247 closed with failing CI) was held by every runner. `pulse.log` showed `Holding #39222 in marcusquinn/aidevops: 4 zero-output or zero-attempt failures within 43200s` on each pass, and the backoff notice said dispatch resumes after 2026-11-20T04:01:31Z.

## What

Trusted output progress on an issue supersedes earlier windowed zero-output and zero-attempt evidence. Progress means a `CLAIM_RELEASED reason=worker_complete`, `worker_merged_partial` or `feedback_route_*` release from a trusted runner, each of which means a worker produced a PR. Failures recorded before that progress no longer count toward the 12-hour zero-attempt backoff, and the local fast-fail state obeys the same boundary. Failures after the boundary still hold exactly as before.

Same boundary family, found while verifying: the hold's own backoff notice never counts as a maintainer reset.

## Why

- Live replay of #39222's comments through the current `_dlw_comment_bloat_metrics_from_json` and `_dlw_hold_repeated_zero_output` gives `hold_rc=0`, with four evidence epochs from 16:01 to 16:29Z. All four are orphan `DISPATCH_LEASE phase=prelaunch` leases from one peer runner.
- After those leases, a trusted runner launched a worker (`phase=ready` at 16:32Z). The worker opened PR #39247, and Pulse posted `CLAIM_RELEASED reason=feedback_route_ci` (17:57Z) to route the CI failure back to the issue. That progress proves the earlier pre-launch aborts are a superseded failure family, yet the hold still blocks the routed repair for about 10 more hours.
- In effect, routed feedback that exists to accelerate repair is silently stalled. The person then has to open an interactive session to push the issue through, which is the instigation cost aidevops exists to remove.
- A ready lease alone must NOT reset the evidence. An issue in a private managed repository shows pre-launch aborts interleaved with `ready` followed by `worker_failed` within a minute. The existing storm fixtures in `tests/test-pulse-dispatch-worker-launch-comment-metrics.sh` also put a trusted ready lease after the failures and still expect a hold. Only completion, partial merge or routed PR feedback count as progress.
- Self-reset: the backoff notice text quotes `<!-- dispatch-infrastructure-reset -->` as an instruction for maintainers, and `reset_notice` did not exclude `breaker_notice`. When the posting runner is OWNER/MEMBER (on an organisation repository, or the owner's own runner), the notice cleared all evidence. The 12-hour hold then lasted one pass and the next cycle burned four more failed attempts before posting another notice. On that private-repo issue, a replay just after its 00:33Z MEMBER notice gave zero evidence on current code. The fixed code gives four, holds until 09:31Z and suppresses a duplicate notice.

## How (Approach)

- `.agents/scripts/pulse-dispatch-worker-prompt.sh`:
  - Move `lease_token` and `evidence_trusted` out of the inline jq program into a new `_DLW_EVIDENCE_TRUST_JQ_DEFS` constant, next to `_DLW_DISPATCH_MARKER_JQ_DEFS`, keeping the `#aidevops:trust-boundary` note. Add `output_progress` (a line-anchored `CLAIM_RELEASED reason=(worker_complete|worker_merged_partial|feedback_route_[a-z]+)`), `progress_key` (latest trusted progress `comment_key`) and `after_key($boundary)`.
  - `_dlw_comment_bloat_metrics_from_json`: carry `key` with the explicit zero-output evidence, unmatched claims and orphan leases. Only items after `$progress_key` enter `$recent_epochs` (column 6 and the CSV in column 8). Breaker notices before progress no longer suppress the notice for a new hold. Column 9 becomes the latest evidence boundary epoch (authoritative reset or trusted output progress), so `_dlw_hold_repeated_zero_output`'s `min_state_epoch` drops local fast-fail state recorded before progress. Lifetime columns 3 and 5 (clean-room arithmetic) and the TSV shape are unchanged.
  - `_dlw_comment_bloat_metrics`: add the progress release pattern to the `_dlw_evidence_trusted_authors` candidate pattern, so a write-verified COLLABORATOR runner's progress release can be trusted. Lookup failure still fails closed.
  - `_DLW_ZERO_OUTPUT_EVIDENCE_JQ_DEFS` `reset_notice`: add `(breaker_notice | not)`, so a backoff notice is never a reset.
- Trust and safety: progress counts only from OWNER/MEMBER or permission-verified write authors. A ready lease, `worker_failed` and the ambiguous `worker_ready_missing_*` releases are not progress. Maintainer reset semantics are unchanged.

### Complexity Impact

`_dlw_comment_bloat_metrics_from_json` was 98 lines. Moving the defs out and changing lines in place leaves it at 93, under the 100-line gate (`complexity-regression-helper.sh check`: no new violations). `_dlw_comment_bloat_metrics` changes one line.

### Files Scope

- `.agents/scripts/pulse-dispatch-worker-prompt.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/pulse-dispatch-worker-prompt.sh` is clean. The existing `tests/test-pulse-dispatch-worker-launch-comment-metrics.sh` and `tests/test-zero-output-url-fallback.sh` pass unchanged, so ready-lease storms still hold.
- A live replay of #39222's comments through the changed functions reports no recent evidence and `hold_rc=1` (dispatch may proceed). A replay of a private-repo issue with ready-then-`worker_failed` loops and no output progress keeps its existing windowed evidence.
- Synthetic check: four trusted orphan leases followed by a trusted `feedback_route_ci` release give recent=0. The same release from an untrusted COLLABORATOR leaves recent=4. Four new failures after the release hold again. A MEMBER backoff notice that quotes the reset marker leaves the four failures counted and the boundary column at 0.
- Live: after deploy, `pulse.log` stops logging `Holding #39222 ... 4 zero-output` and the issue is dispatched on a subsequent pass, unless it was already resolved.
