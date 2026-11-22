## What

`issue-sync-helper.sh close` (bulk mode) must not close an open issue, or rewrite a completed TODO row's `ref:GH#N`, when the issue matched only by the leading `tNNN` in its title and the TODO row already references a different issue. Treat that as a task-ID title collision: skip it and log it.

## Why

Bulk close builds a `task-id -> open issue` map from titles matching `^tNNN[ :]`. For each completed TODO row it then closes the mapped issue. If the row's `ref:GH#` differs, it calls `fix_gh_ref_in_todo` to repoint the row. An open issue whose title starts with an old task ID used as a topic is therefore falsely closed as done. The rewrite can also repoint a historical row to an unrelated issue.

Observed 2026-11-17: GH#38909 ("t2449 merge verdict reports 'trust metadata unavailable' …") was closed by `github-actions` at 23:59:31Z as "Completed via PR #20283. Task t2449 done in TODO.md", with `status:done` and `solved:worker` added. Its worker PR #38917 was still open and unmerged. TODO.md's t2449 row is `[x] … ref:GH#20164 … pr:#20283 completed:2026-04-21`. The issue was manually reopened and restored to `status:in-review`. A false completion hides unfinished work from Pulse redispatch and from the user.

## How

- EDIT `.agents/scripts/issue-sync-helper-close.sh` `cmd_close` bulk loop (the `ref` vs `issue_num` block, currently ~line 660-671): when `ref` is non-empty and `!= issue_num`, log `task-ID title collision` with the row ref and the open issue number, increment `skipped`, and `continue`. Do not call `fix_gh_ref_in_todo` or `_do_close`. Keep the empty-ref branch, which adds the ref and then closes, unchanged.
- Reference pattern: the single-task mode in the same function already trusts the row's `ref:GH#` first and uses title lookup only when no ref exists.
- EDIT `.agents/scripts/tests/test-issue-sync-completion-evidence.sh` bulk-close case (~line 323-344): add a completed row `- [x] t2449 historical row ref:GH#20164` and an open issue `{"number":38909,"title":"t2449 topical reference"}`. Assert that `BULK_CLOSED` does not include `t2449|38909` and the summary counts it as skipped.

### Files Scope

- `.agents/scripts/issue-sync-helper-close.sh`
- `.agents/scripts/tests/test-issue-sync-completion-evidence.sh`

## Acceptance

- Completed row with ref equal to the title-mapped open issue still closes it.
- Completed row with no ref still adds the ref and closes it.
- Completed row whose ref differs from the title-mapped open issue is skipped. Neither the close nor the TODO ref rewrite happens.

## Verification

```bash
bash .agents/scripts/tests/test-issue-sync-completion-evidence.sh
bash .agents/scripts/tests/test-issue-sync-ref-comments.sh
shellcheck -x -P .agents/scripts .agents/scripts/issue-sync-helper-close.sh
```
