## What

Reopened issues keep their assignee from the finished lifecycle, and the pulse then orders them behind all fresh work. In a deep backlog they are not attempted at all.

Observed on a managed product repo (2026-11-17..18). A completion-phase worker found that two closed sibling issues had unfinished rows, so it reopened them with an explanation. `_action_rsd_single` healed both from open + `status:done` to `status:available`. Each one still had the previous worker's assignee: the repo maintainer, who is also the local runner login. In the next 10-16 hours neither issue showed up in the local pulse log, although the dispatcher made several hundred attempts on other issues in that time. The completion phase that depends on them stayed blocked.

There are two causes:

1. `_action_rsd_single` in `.agents/scripts/pulse-issue-reconcile-actions.sh` sets `status:available` but leaves assignees in place. Those assignees came from the closed lifecycle and no longer hold a claim.
2. In `.agents/scripts/pulse-dispatch-engine.sh`, `_dispatch_order_claim_state_candidates` (GH#38333) counts any assignee as a claim and moves the candidate after all unclaimed work. Dispatch dedup (`_is_assigned_compute_blocking` in `.agents/scripts/dispatch-dedup-assignment.sh`, GH#18352/t1996) treats self, repo owner and repo maintainer as passive when there is no active claim, so these candidates would pass the assignee gate cheaply. GH#38333 was justified by claimed candidates that the guards rejected after 27-75s each. Passive-only assignees do not hit that cost.

## How

- EDIT `.agents/scripts/pulse-issue-reconcile-actions.sh`:
  - Add `_pir_prior_lifecycle_assignees <slug> <issue> <issue_json>`. Read the issue events once with `gh api --paginate`, find the latest `reopened` time, and print each current assignee that has no `assigned` event at or after that time, comma-joined. Print nothing, and do no cleanup, if the issue was never reopened, if the events read fails, or if a timestamp is malformed. Reuse the `_PIR_ISO_UTC_RE` check from `_pir_latest_reopen_at`.
  - `_action_rsd_single`: when `restored_status` is `available` and that helper prints logins, pass `--remove-assignee <logins>` to `set_issue_status`. If that combined edit fails, heal the status alone, as before, so assignee cleanup can never block the heal. Log the removed logins on the existing "healed" line. A `blocked` restore keeps its assignees.
- EDIT `.agents/scripts/pulse-dispatch-engine.sh` `_dispatch_order_claim_state_candidates`: an assignee counts as claimed unless the candidate has all of the following, mirroring `_has_active_claim` plus `_is_assigned_compute_blocking`:
  - no `status:queued`, `status:in-progress`, `status:in-review` or `status:claimed` label
  - no `origin:interactive` without `auto-dispatch`
  - only assignees in {`$_DISPATCH_SELF_LOGIN`, the repo owner from `repo_slug`, the repo maintainer from `$REPOS_JSON`}

  Keep the existing label half and the fail-open behaviour: if jq fails, the input comes back unchanged. If the maintainer map is unreadable, use an empty map, which keeps the current strict demotion.

### Files Scope

- .agents/scripts/pulse-issue-reconcile-actions.sh
- .agents/scripts/pulse-dispatch-engine.sh
- todo/tasks/t19110-brief.md
- TODO.md

## Acceptance Criteria

- [ ] An open + `status:done` issue reopened after its assignee was assigned heals to `status:available` with that assignee removed.
- [ ] An assignee added at or after the latest reopen is kept. A never-reopened issue keeps all its assignees. A failed events read keeps assignees and still heals the status.
- [ ] A `status:available` candidate whose assignees are only self, owner or maintainer, with no active label and no interactive hold, stays in the fresh lane. A candidate with any other assignee, an active label, or `origin:interactive` without `auto-dispatch` is still demoted.
- [ ] `bash .agents/scripts/tests/test-open-done-nonclosing-regression.sh`, `bash .agents/scripts/tests/test-pulse-issue-reconcile.sh` and the GH#38333 ordering tests pass, and ShellCheck is clean on both files.

## Verification

- `shellcheck .agents/scripts/pulse-issue-reconcile-actions.sh .agents/scripts/pulse-dispatch-engine.sh`
- `bash .agents/scripts/tests/test-open-done-nonclosing-regression.sh`
- `rg -l '_dispatch_order_claim_state_candidates' .agents/scripts/tests`, then run every suite it lists.
- Ad hoc: run the real `_action_rsd_single` with stubbed `gh` events (reopen after assignment, assignment after reopen, never reopened, failed read), and run the real `_dispatch_order_claim_state_candidates` on fixture candidates.
- After deploy, check `~/.aidevops/logs/pulse.log`: "healed open + status:done ... removed prior-lifecycle assignees", a lower fresh-first demotion count, and reopened maintainer-assigned issues being attempted.
