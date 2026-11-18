## What

A worker that releases an issue as `blocked` after opening a draft leaves the draft as a checkpoint. The draft then holds the issue until someone publishes a revision-bound `CHECKPOINT_CONTINUATION_APPROVED` line. Terminal-blocker recovery can later re-arm that issue, either for a maintainer retry directive (`trusted_retry`) or for a brief revision after the blocker (`revision_changed`). It posts its receipt and projects `status:available`. The checkpoint path ignores that re-arm. `_pcc_blocked_attention` posts or re-finds `BLOCKED_CHECKPOINT_ATTENTION` and the draft stays held, even when the approval template validates (`refusal=none`).

The two opt-in policy routes in `_pcc_policy_route` do not cover this case either. `_pcc_resolve_decision` needs a `reason=decision` finding. `_pcc_unknown_pending_work` needs a `CHECKPOINT_UNKNOWN_TRIAGE pending_work` marker bound to the current brief, and a revised brief by definition no longer matches it. Without the policy, the unknown digest also needs that marker. So a re-armed blocked checkpoint has no route at all. A maintainer retry directive, the strongest human signal available, is silently ignored, and the issue looks healthy (`status:available`) while nothing can run.

Evidence from one runner on 2026-11-18:

- Census of open drafts held by blocked-checkpoint attention across pulse repos: 9 open. Of those, 4 already have a trusted re-arm receipt after the blocked release: 2 `trusted_retry`, 1 `revision_changed` and 1 `unevidenced_permission_window`. All 4 show `refusal=none` in the attention marker, and none has an approval. The other 5 have no re-arm.
- One worked example in a private managed repository: blocked release 14:30Z (`reason=unknown`). At 16:03Z the recovery supervisor repaired the brief and wrote "continue draft PR, do not restart; cause: environment, not brief". At 17:03Z a runner posted `terminal-blocker-rearmed` (`reason=revision_changed`). At 17:04Z it posted `BLOCKED_CHECKPOINT_ATTENTION ... refusal=none`. More than 50 hours later the draft is untouched and every pulse round spends a dispatch ceremony ending in `worker_draft_checkpoint_blocked`.
- `~/.aidevops/logs/pulse.log`: 35 distinct drafts reached `BLOCKED_CHECKPOINT_ATTENTION_EXISTS`, with zero `UNKNOWN_CHECKPOINT_APPROVED` outcomes.

## How

- EDIT `.agents/scripts/pr-checkpoint-decision-resolver.sh`: add a third step to `_pcc_policy_route`, after `_pcc_resolve_decision` and `_pcc_unknown_pending_work`. Call a new `_pcc_rearmed_checkpoint_route` with the same arguments. It returns 0 only after it publishes an approval or adds a digest entry.
- NEW function `_pcc_rearmed_checkpoint_route`, in the same file or `pr-checkpoint-unknown-digest.sh` to keep files small. Model it on `_pcc_unknown_pending_work`:
  1. Find the newest unedited comment, created after the blocked release `$release`, that contains both `<!-- aidevops:terminal-blocker-rearmed key=` and `<!-- aidevops:terminal-blocker-rearm-reason reason=(trusted_retry|revision_changed) `. Exclude `unevidenced_permission_window` and `lifecycle_recovered`. Neither shows that the blocker was addressed.
  2. #aidevops:trust-boundary: require the receipt poster to have current `admin|maintain|write` permission (`repos/{repo}/collaborators/{login}/permission`), as `_pcc_decision_recorded` does. For `trusted_retry`, also require the newest retry directive comment (`_terminal_blocker_latest_retry_comment` semantics: OWNER/MEMBER, unedited) to be newer than `$release`.
  3. Run the same gates as `_pcc_unknown_pending_work`: `_pr_checkpoint_pr_metadata_is_eligible`, then open/unassigned/`auto-dispatch`/no protective hold on the issue. Generate the template with `_pcc_approval_template` and check that its `head` and `brief_sha256` match the current head and brief.
  4. Publish through `_pcc_publish_policy_approval` when the repo has `checkpoint_policy.auto_continue_unknown_pending_work == true` and `_pcc_policy_permissions` passes. Do the same for `trusted_retry` when only the publishing login and the retry author pass the permission check: the maintainer directive is the authority. Print `REARMED_CHECKPOINT_APPROVED pr=… head=… release=… reason=…`.
  5. Otherwise (`revision_changed` with no policy) return 1 and keep today's attention behaviour. Do not touch `_pcc_unknown_digest`: its snapshot reads only `status:blocked` issues that carry the triage marker, and widening it is separate work.
- EDIT `.agents/reference/checkpoint-revision-recovery.md`, policy section: add one short paragraph on the re-armed route and its gates.
- EDIT `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`: extend the existing policy cases (pattern near the `CHECKPOINT_UNKNOWN_TRIAGE` fixture) with a `trusted_retry` re-arm that publishes without policy and a `revision_changed` re-arm that publishes only with policy. Add a receipt from a non-write login, one older than the release, and an `unevidenced_permission_window` receipt; none of these publish.

### Files Scope

- .agents/scripts/pr-checkpoint-decision-resolver.sh
- .agents/scripts/pr-checkpoint-unknown-digest.sh
- .agents/reference/checkpoint-revision-recovery.md
- .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh
- TODO.md

## Acceptance Criteria

- [ ] A blocked worker draft whose issue has a newer, write-authorised `trusted_retry` re-arm receipt and a validating template gets exactly one `CHECKPOINT_CONTINUATION_APPROVED` line through `gh-write-helper.sh`, with or without checkpoint policy. The next dispatch round continues the exact head through `dispatch-approved`.
- [ ] A `revision_changed` re-arm publishes only when the repo has `auto_continue_unknown_pending_work`; without it the existing attention hold is unchanged.
- [ ] No approval is published for: a receipt from a login without write permission; a receipt older than the blocked release; `unevidenced_permission_window` or `lifecycle_recovered` reasons; an assigned or held issue; or a template whose head or brief no longer matches.
- [ ] Existing checkpoint suites pass: `test-pr-checkpoint-continuation-dispatch.sh` and `test-pr-checkpoint-continuation-helper.sh`. ShellCheck is clean on the edited files.

## Verification

- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `shellcheck .agents/scripts/pr-checkpoint-decision-resolver.sh .agents/scripts/pr-checkpoint-unknown-digest.sh`
- After deploy: `rg -c 'REARMED_CHECKPOINT_APPROVED' ~/.aidevops/logs/pulse.log` grows. The two `trusted_retry` drafts from the census get approvals and continuation launches within one pulse round.
