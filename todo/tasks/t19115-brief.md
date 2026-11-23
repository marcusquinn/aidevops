## What

A worker that releases an issue as `blocked` after opening a draft leaves the draft as a checkpoint. The draft then holds the issue until someone publishes a revision-bound `CHECKPOINT_CONTINUATION_APPROVED` line. Terminal-blocker recovery can later re-arm that issue, either for a maintainer retry directive (`trusted_retry`) or for a brief revision after the blocker (`revision_changed`). It posts its receipt and projects `status:available`. The checkpoint path ignores that re-arm. `_pcc_blocked_attention` posts or re-finds `BLOCKED_CHECKPOINT_ATTENTION` and the draft stays held, even when the approval template validates (`refusal=none`).

The two opt-in policy routes in `_pcc_policy_route` do not cover this case either. `_pcc_resolve_decision` needs a `reason=decision` finding. `_pcc_unknown_pending_work` needs a `CHECKPOINT_UNKNOWN_TRIAGE pending_work` marker bound to the current brief, and a revised brief by definition no longer matches it. Without the policy, the unknown digest also needs that marker. So a re-armed blocked checkpoint has no route at all. A maintainer retry directive, the strongest human signal available, is silently ignored, and the issue looks healthy (`status:available`) while nothing can run.

Evidence from one runner on 2026-11-18:

- Census of open drafts held by blocked-checkpoint attention across pulse repos: 9 open. Of those, 4 already have a trusted re-arm receipt after the blocked release: 2 `trusted_retry`, 1 `revision_changed` and 1 `unevidenced_permission_window`. All 4 show `refusal=none` in the attention marker, and none has an approval. The other 5 have no re-arm.
- One worked example in a private managed repository: blocked release 14:30Z (`reason=unknown`). At 16:03Z the recovery supervisor repaired the brief and wrote "continue draft PR, do not restart; cause: environment, not brief". At 17:03Z a runner posted `terminal-blocker-rearmed` (`reason=revision_changed`). At 17:04Z it posted `BLOCKED_CHECKPOINT_ATTENTION ... refusal=none`. More than 50 hours later the draft is untouched and every pulse round spends a dispatch ceremony ending in `worker_draft_checkpoint_blocked`.
- `~/.aidevops/logs/pulse.log`: 35 distinct drafts reached `BLOCKED_CHECKPOINT_ATTENTION_EXISTS`, with zero `UNKNOWN_CHECKPOINT_APPROVED` outcomes.

## How

- EDIT `.agents/scripts/pr-checkpoint-decision-resolver.sh`: in `_pcc_policy_route`, call a new `_pcc_rearmed_checkpoint_route` after `_pcc_resolve_decision` and before `_pcc_unknown_pending_work`. A trusted re-arm is newer evidence than the release-time triage. The new route returns 0 only when an approval is published or already valid.
- NEW function `_pcc_rearmed_checkpoint_route` in the same file, modelled on `_pcc_unknown_pending_work`:
  1. Find the newest unedited comment, created after the blocked release `$release`, that contains both `<!-- aidevops:terminal-blocker-rearmed key=` and a `terminal-blocker-rearm-reason` line with `reason=trusted_retry` or `reason=revision_changed`. Exclude `unevidenced_permission_window` and `lifecycle_recovered`. Neither shows that the blocker was addressed.
  2. #aidevops:trust-boundary: the receipt poster, the publishing login and the checkpoint runner need current `admin|maintain|write` permission. For `trusted_retry`, also require an unedited OWNER/MEMBER `terminal-blocker-circuit:retry` directive between the release and the receipt, posted by a login with write permission. For `revision_changed`, require the issue author to have write permission: only the author or a write collaborator can edit an issue body, so every revision is then trusted.
  3. Run the same gates as `_pcc_unknown_pending_work`: `_pr_checkpoint_pr_metadata_is_eligible`, then open/unassigned/`auto-dispatch`/no protective hold on the issue. Generate the template with `_pcc_approval_template` and check that its `head` and `brief_sha256` match the current head and brief.
  4. Reserve `refs/aidevops/checkpoint-rearm/<issue>/<receipt>` atomically: two runners publishing would leave an ambiguous approval. Then publish through `_pcc_publish_policy_approval` and print `REARMED_CHECKPOINT_APPROVED pr=… head=… release=… reason=… receipt=…`.
  5. On by default, matching the re-arm's own trust decision. A repo opts out with `checkpoint_policy.auto_continue_rearmed: false`. Do not touch `_pcc_unknown_digest`.
- EDIT `.agents/reference/checkpoint-revision-recovery.md`: add a short "Re-armed blocked checkpoints" subsection covering the evidence, authority, gates and bounds.
- EDIT `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`, following the `test_unknown_pending_policy` pattern. Cover `trusted_retry` and trusted `revision_changed` publishing exactly once, and a lost reservation not republishing. None of these may publish: a receipt from a non-write poster, a non-write retry or issue author, a COLLABORATOR or edited retry, an older or edited receipt, permission-window and lifecycle reasons, an assigned or held issue, a moved head, or an opted-out repo.

### Files Scope

- .agents/scripts/pr-checkpoint-decision-resolver.sh
- .agents/scripts/pr-checkpoint-unknown-digest.sh
- .agents/reference/checkpoint-revision-recovery.md
- .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh
- TODO.md

## Acceptance Criteria

- [ ] A blocked worker draft whose issue has a newer, write-authorised `trusted_retry` re-arm receipt and a validating template gets exactly one `CHECKPOINT_CONTINUATION_APPROVED` line through `gh-write-helper.sh`, with or without checkpoint policy. The next dispatch round continues the exact head through `dispatch-approved`.
- [ ] A `revision_changed` re-arm publishes the same way when the issue author has write permission; with an outside author it never publishes.
- [ ] No approval is published for: a receipt, retry or brief from a login without write permission; a receipt older than the blocked release; `unevidenced_permission_window` or `lifecycle_recovered` reasons; an assigned or held issue; a template whose head or brief no longer matches; or a repo with `auto_continue_rearmed: false`.
- [ ] Existing checkpoint suites pass: `test-pr-checkpoint-continuation-dispatch.sh` and `test-pr-checkpoint-continuation-helper.sh`. ShellCheck is clean on the edited files.

## Verification

- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`
- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh`
- `shellcheck .agents/scripts/pr-checkpoint-decision-resolver.sh .agents/scripts/pr-checkpoint-unknown-digest.sh`
- After deploy: `rg -c 'REARMED_CHECKPOINT_APPROVED' ~/.aidevops/logs/pulse.log` grows. The two `trusted_retry` drafts from the census get approvals and continuation launches within one pulse round.
