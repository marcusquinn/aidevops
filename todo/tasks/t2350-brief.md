<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2350 Brief — pulse: auto-rebase or auto-close DIRTY PRs

**Issue:** GH#TBD (filed alongside this brief).

## Session origin

Discovered 2026-04-18 during board-clearing session. Three `origin:interactive` PRs (#19754, #19703, #19696) had accumulated merge conflicts with main (`mergeStateStatus: DIRTY`) and sat unmerged for 1-2 days. Each required interactive rebase + triage decision (#19754 and #19703 closed as superseded; #19696 rebased and merged). The pulse has no periodic sweep for DIRTY PRs, so stuck PRs accumulate until an interactive session clears them.

## What

Add a pulse-stage scanner that detects DIRTY PRs and takes one of two actions based on age and content:

- **Auto-rebase**: if PR is <48h old AND has real code changes AND only TODO.md is conflicting → rebase onto `origin/main`, resolve TODO.md by accepting HEAD + re-inserting the PR's task entry at correct chronological position, force-push.
- **Auto-close**: if PR is >7d old AND hasn't had a human push in 3d → close with a comment explaining "superseded by subsequent merges" and link to any issue that remains open for worker re-dispatch.

## Why

- Interactive users file planning PRs (TODO.md + brief file) that go DIRTY within hours of any other TODO.md push.
- Workers that complete work but get delayed through review bot gate age into DIRTY.
- Nobody schedules manual DIRTY-PR triage, so stuck PRs pile up until a session notices them.
- Both actions (rebase if possible, close if stale) are deterministic and idempotent — no human judgment needed in the common case.

## How

**NEW: `.agents/scripts/pulse-dirty-pr-sweep.sh`** — new pulse stage.

**EDIT: `.agents/scripts/pulse-wrapper.sh`** — register the new stage after the merge pass.

**Reference pattern**: model on `.agents/scripts/pulse-merge.sh` (pulse stage lifecycle: state file, dedup lock, gh query loop, comment on action).

### Detection

```bash
gh pr list --state open --json number,mergeStateStatus,updatedAt,author,labels,files \
  --jq '.[] | select(.mergeStateStatus == "DIRTY")'
```

### Auto-rebase path

Eligibility: all true:
- `mergeStateStatus == "DIRTY"`
- PR age < 48h
- `author.login == OWNER || labels contains "origin:worker"`
- Conflicting files list (from `git merge-tree --write-tree`) includes ONLY TODO.md
- Branch still exists on origin

Action:
1. Create ephemeral worktree for the PR branch.
2. Attempt `git rebase origin/main`. If ONLY TODO.md conflicts, resolve via `git checkout --ours TODO.md` + re-insert the PR's task entry (extracted via `git show $commit -- TODO.md`) at correct chronological position.
3. `git push --force-with-lease origin <branch>`.
4. Remove ephemeral worktree.
5. Post PR comment documenting the rebase.

### Auto-close path

Eligibility: all true:
- `mergeStateStatus == "DIRTY"`
- PR age > 7d
- No human commits in last 3d (check `commits[-1].author.login` against repo maintainer list)
- No `do-not-close` label

Action:
1. Post PR comment explaining closure (template with issue back-link if applicable).
2. `gh pr close --delete-branch`.

### Safety gates

- Dry-run mode (`DRY_RUN=1` env var) prints would-be actions without executing.
- Never rebases a PR with non-TODO.md conflicts — escalate to a maintainer-review comment instead.
- Never auto-closes a PR with `do-not-close` label OR linked to an OPEN issue with `parent-task` label.
- Audit log: every action written to `audit-log-helper.sh log dirty-pr-sweep`.

## Acceptance criteria

1. `pulse-dirty-pr-sweep.sh --dry-run` against current repo lists 0 or more DIRTY PRs with the proposed action (rebase / close / escalate).
2. Test harness `tests/test-dirty-pr-sweep.sh` with fixtures for all three paths.
3. Registered in `pulse-wrapper.sh` to run every Nth pulse cycle (every 30min is fine — not per-cycle).
4. Idempotent — re-running within 30min doesn't re-action the same PR.
5. Never rebases `parent-task` PRs (those have their own rules).
6. Verification: open a fixture DIRTY PR, run the sweep, confirm rebase succeeds OR close fires per eligibility.

## Tier

`tier:thinking` — architectural decisions (which pulse stage, what eligibility windows, rebase conflict resolution heuristics) benefit from deeper reasoning. NOT `tier:simple` — many judgment calls.

## Related

- PR #19696 (rebased manually during this session) — canonical eligible-for-auto-rebase case.
- PRs #19754, #19703 (closed manually during this session) — canonical eligible-for-auto-close case.
