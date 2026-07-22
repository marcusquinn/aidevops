# Issue-sync synthetic pull-request ref checkout research

## Status

- GitHub issue: GH#28506
- Task ID: t18270 allocated offline after `claim-task-id.sh` failed because
  `origin/main` rejects the counter CAS push.
- Brief: `todo/tasks/t18270-brief.md`; reconcile the offline allocation before
  dispatch.

## Observed failure

The `forge-event` job checks out the caller repository without an explicit ref
and authenticates with `${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}`. On a
`pull_request` event, `actions/checkout` follows GitHub's synthetic
`refs/pull/<number>/merge` ref. A valid fine-grained PAT can receive HTTP 403
while fetching that ref.

Evidence:

- `.github/workflows/issue-sync-reusable.yml:59-77` defines the job and checkout.
- `.agents/templates/workflows/issue-sync-caller.yml:37-38` enables PR opened,
  edited, closed, and reopened events.

## Contract findings

### Repository contents are required for issue projection

`forge-event-mapping-helper.sh` only maps `issues` events and resolves the task
from the checked-out `TODO.md`. Accepted issue transitions can then run
`task-projection-reducer.mjs` against `REPOSITORY_PATH/TODO.md`.

- `.agents/scripts/forge-event-mapping-helper.sh:10-32`
- `.github/workflows/issue-sync-reusable.yml:94-115`
- `.agents/scripts/task-coordinator.mjs:678-721`
- `.agents/scripts/task-projection-reducer.mjs:39-48`

Issue and reconcile events therefore need a canonical default-branch planning
projection, not an event-dependent PR merge checkout.

### PR events currently have no PR-to-task mapping

The mapping helper exits for every event except `issues`. The coordinator tries
to resolve non-push events by immutable subject ID, but issue mappings contain
issue node IDs, not pull-request node IDs. An ordinary PR event is therefore
unmapped and creates no publication intent.

- `.agents/scripts/forge-event-mapping-helper.sh:10-16`
- `.agents/scripts/task-coordinator.mjs:691-713`
- `.agents/scripts/tests/test-task-coordinator.sh:230-233`

The caller test asserts that opened/edited/reopened triggers exist, but no test
proves those PR actions have a semantic coordinator effect:

- `.agents/scripts/tests/test-forge-event-workflow.sh:33-39`

Before preserving those events, implementation must define and test a real
PR-to-task mapping contract. Otherwise the canonical PR trigger can be reduced
to `types: [closed]`; merged-PR completion remains implemented by the legacy
issue-sync merge job, not by the currently unmapped coordinator event.

### A universal default-branch ref is unsafe for push projections

Push events use `github.event.after` as their immutable subject identity. A
checkout of the branch name can resolve to a later commit when runs queue,
making repository contents disagree with the event SHA and cursor. The
coordinator push path currently records ordering without projecting a task, but
the co-running `sync-on-push` job consumes the triggering checkout. Push
checkouts must retain immutable event-revision semantics.

- `.github/workflows/issue-sync-reusable.yml:102-104,147-160,200-232`
- `.agents/scripts/task-coordinator.mjs:678-713`
- `.agents/scripts/tests/test-task-coordinator.sh:263-270`

## Recommended design

1. Separate the forge-event repository projection from event-default checkout
   behavior.
2. Authenticate this read-oriented checkout with `secrets.GITHUB_TOKEN`; keep
   `SYNC_PAT` only where a job must commit or push planning changes.
3. Select the projection ref by event contract:
   - `issues` and workflow-dispatch reconcile/audit: caller default branch.
   - `push`: immutable `${{ github.event.after }}` when repository contents are
     consumed.
   - `pull_request`: skip repository checkout when ingestion is metadata-only,
     or use a trusted base/default-branch projection when canonical TODO data is
     required; never implicitly fetch `refs/pull/*/merge`.
4. Decide the canonical PR trigger set from tested semantics:
   - If no PR mapping is added, use `types: [closed]` and document that legacy
     merge hygiene owns linked-task completion.
   - If opened/edited/reopened remain, add PR-to-task mapping and observable
     transition tests first.
5. Review whether `forge-event` can reduce `contents: write` to `contents: read`.
   Do not reduce it until publication behavior and permissions have been traced
   end-to-end.

## Implementation surface

- `EDIT: .github/workflows/issue-sync-reusable.yml`
- `EDIT IF trigger contract changes: .github/workflows/issue-sync.yml`
- `EDIT IF trigger contract changes: .agents/templates/workflows/issue-sync-caller.yml`
- `EDIT: .agents/scripts/tests/test-forge-event-workflow.sh`
- `EDIT: .agents/scripts/tests/test-reusable-workflow-caller.sh`
- `EDIT ONLY WITH EVIDENCE: .agents/scripts/check-workflows-helper.sh`
- `EDIT ONLY WITH EVIDENCE: .agents/scripts/sync-workflows-helper.sh`

## Acceptance criteria

- [ ] No PR event causes any checkout to fetch `refs/pull/*/merge` with
  `SYNC_PAT`.
- [ ] Read-only forge projection uses `GITHUB_TOKEN`; write-capable sync paths
  retain `SYNC_PAT` and explicit cross-account secret forwarding.
- [ ] Issue and reconcile events read canonical default-branch `TODO.md`.
- [ ] Push synchronization reads the immutable triggering revision, not a later
  branch tip.
- [ ] Closing an unmerged PR does not complete tasks.
- [ ] Merging a PR with a supported linked-task reference still performs
  completion hygiene exactly once.
- [ ] Every canonical PR trigger has an asserted semantic effect; unsupported
  triggers are removed from both callers.
- [ ] A resynced downstream caller classifies as `CURRENT/CALLER`.

## Verification plan

```bash
bash .agents/scripts/tests/test-reusable-workflow-caller.sh
bash .agents/scripts/tests/test-forge-event-workflow.sh
bash .agents/scripts/tests/test-forge-event-mapping.sh
bash .agents/scripts/tests/test-forge-event-reconciliation.sh
bash .agents/scripts/tests/test-task-coordinator.sh
bash .agents/scripts/tests/test-check-workflows-helper.sh
bash .agents/scripts/tests/test-check-workflows-classifier.sh
bash .agents/scripts/tests/test-check-workflows-runner-normalise.sh
bash .agents/scripts/tests/test-sync-workflows-helper.sh
bash .agents/scripts/tests/test-lint-workflows-helper.sh
bash .agents/scripts/lint-workflows-helper.sh \
  .github/workflows/issue-sync-reusable.yml \
  .github/workflows/issue-sync.yml
```

Downstream event matrix:

1. Open, edit, and reopen a PR if those triggers remain canonical.
2. Close an unmerged PR.
3. Merge a PR with a supported closing reference.
4. Push a planning-file commit and prove the consumed revision equals the
   event's `after` SHA.
5. Run `aidevops check-workflows --repo <owner/repo>` and require
   `CURRENT/CALLER`.

## Hazards

- Do not broaden PAT permissions.
- Do not execute untrusted PR-head code in a privileged reusable workflow.
- Do not solve the failure by suppressing workflow drift detection.
- Do not assume green workflow execution proves correct event projection; tests
  must assert the selected ref and resulting transition.
- Re-check recent forge coordinator changes before implementation. Commit
  `b36a83d49` (PR #28468) recently changed targeted projection behavior.
