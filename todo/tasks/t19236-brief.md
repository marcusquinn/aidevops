## What

Make `gh-checks-wait-helper.sh wait` (and `full-loop-helper.sh wait-checks`, which calls it) end early when required checks are missing because the PR conflicts with its base. GitHub does not start `pull_request` workflows for a PR whose merge ref cannot be built, so those required contexts never appear. Today the waiter polls until its timeout (1800 s interactive, 200 s headless) and then reports a pending timeout. It should report the conflict and the rebase step instead.

## Why

Evidence from marcusquinn/aidevops PR #39617, 2026-11-21:

- Head `407ca8d4` was pushed while `TODO.md` conflicted with `main` (`git merge-tree --write-tree origin/main HEAD` gave `CONFLICT (content): Merge conflict in TODO.md`). `pull_request_target` gates ran. No `pull_request` workflow run was created for that head in more than 20 minutes (`gh run list --event pull_request` showed 0). `wait-checks` stayed in heartbeat with `missing=Complexity Analysis, Framework Validation, Qlty Regression Gate` for about 23 minutes, until the session diagnosed the conflict by hand.
- After a rebase, head `63160baf` had 21 `pull_request` runs within about a minute.
- `TODO.md` conflicts are common because planning lines land on `main` all the time (PR #39596 hit the same conflict in the same session). Every interactive or worker wait on such a PR loses its whole timeout and then needs manual diagnosis.

## How

- Model on `classify_draft_stall` (`.agents/scripts/gh-checks-wait-helper.sh:789-812`), which ends a stalled draft wait with `WAIT_CHECKS=draft-required-missing` and exit 9. Add a sibling `classify_conflict_stall`, called from `wait_for_checks` next to the draft check (around lines 907-910).
- Trigger: `required_only` is set, `missing_contexts` is non-empty, `elapsed >= _GCW_EMPTY_REQUIRED_SETTLE_SECONDS` (line 25, default 90 s), and one PR read (`gh pr view <n> --repo <r> --json mergeable,baseRefName`) returns `mergeable == "CONFLICTING"`. `UNKNOWN` while GitHub computes is not a conflict; keep waiting. Read it at most once per heartbeat interval, not every poll, to limit REST cost.
- On trigger: re-verify the head as the draft path does (`verified_head_sha`; a changed head restarts observation), print `WAIT_CHECKS=conflict-required-missing: PR <n> conflicts with <base>; rebase onto origin/<base>, push, then wait again`, and return a new distinct exit code (10). Document it in the usage text (lines 57-60).
- Fixture mode: follow how `read_draft_state` reads fixtures under `AIDEVOPS_GH_CHECKS_FIXTURE_DIR`, so a fixture can supply `mergeable`.
- Check `full-loop-helper.sh` `cmd_wait_checks` (around line 507) and any caller that switches on waiter exit codes (`rg -n "gh-checks-wait-helper.sh\" wait|wait-checks" .agents/scripts`). Treat 10 like 9: actionable and non-terminal, not a CI failure.

## Files Scope

- `.agents/scripts/gh-checks-wait-helper.sh`
- `.agents/scripts/full-loop-helper.sh`

## Acceptance

- With required contexts missing, `mergeable=CONFLICTING`, and elapsed past the settle window, the waiter prints the `WAIT_CHECKS=conflict-required-missing` line and exits 10 within one heartbeat interval.
- `mergeable=UNKNOWN` or `MERGEABLE` with missing contexts keeps the current pending behaviour.
- Draft, zero-job, failure, success and head-change paths are unchanged.
- Existing waiter tests pass: `rg -l "gh-checks-wait-helper" .agents/scripts/tests`, then run each with `bash`.

## Verification

- `shellcheck -x .agents/scripts/gh-checks-wait-helper.sh .agents/scripts/full-loop-helper.sh`
- The waiter tests found above.
- Runtime: on a scratch PR that conflicts with its base, `full-loop-helper.sh wait-checks <PR> --repo <owner/repo>` exits 10 with the rebase line in about 90-210 s instead of timing out.
