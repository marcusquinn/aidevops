# t18575: fix(claim-task-id): write auto-detected GH# predecessors as task IDs in the TODO line so publication can parse it

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33159
- **Conversation context:** Found while publishing framework value audit tasks t18572 and t18574; their claim-generated TODO lines failed planning publication.

## What

When `claim-task-id.sh` auto-detects a predecessor (GH#20834), the TODO line it writes, or prints for canonical checkouts, contains `blocked-by:GH#NNN`. The issue-sync parser rejects that form, so planning publication never reconciles the task. It stays `publication:pending` and never dispatches.

## Why

Observed on 2026-09-30 with t18572 (GH#33148) and t18574 (GH#33150):

- `claim-task-id.sh` auto-detected GH#33135 as the predecessor of t18574 and suggested a TODO line whose dependency field used the `GH#NNN` form.
- After that line merged, `full-loop-helper.sh merge` reported `t18574/#33150: task line parse failed; retaining publication:pending`. t18572 failed the same way.
- Every other task in the same PR reconciled.
- Rewriting the dependency fields to the task IDs t18563 and t18571 made `parse_task_line` succeed.

Root cause:

- `.agents/scripts/claim-task-id-issue.sh:739-741` appends `blocked-by:${_CLAIM_BLOCKED_BY_REFS}` verbatim, and that value can hold `GH#NNN` refs (`claim-task-id.sh:1573-1575`).
- `_task_dependency_value` in `.agents/scripts/issue-sync-lib-parse.sh:248-263` validates through `task_identity_parse_list`, which accepts only task IDs. Every `blocked-by:` in TODO.md uses task IDs.

## How

1. In `claim-task-id-issue.sh` `_ensure_todo_entry_written` (around `:736-741`), map each `GH#NNN` in `_CLAIM_BLOCKED_BY_REFS` to its task ID:
   - First, the TODO.md line carrying `ref:GH#NNN`.
   - Otherwise, the issue title prefix `tNNN:` using the existing gh wrappers.

   Write only task IDs into the TODO line. If a ref cannot be resolved, omit it from the TODO line and log a warning. The GitHub `blocked-by:GH#NNN` label and the native relationship stay unchanged.
2. Leave `task_identity_parse_list` strict. Widening a shared parser is out of scope.

## Reference pattern

Reuse the task-ID lookup in `.agents/scripts/task-identity-lib.sh`, if it resolves `ref:GH#` to a task ID. Otherwise follow the `ref:GH#` grep already in `claim-task-id-issue.sh`.

### Files Scope

- `.agents/scripts/claim-task-id-issue.sh`
- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/tests/test-claim-task-id-blocked-by-todo.sh`

## Acceptance criteria

- [ ] A description naming a predecessor `GH#NNN` whose issue title is `tMMM: ...` produces a TODO line containing `blocked-by:tMMM` and no `blocked-by:GH#`.
- [ ] `parse_task_line` accepts the generated line (rc 0, `blocked_by=tMMM`).
- [ ] The GitHub `blocked-by:GH#NNN` label and sub-issue or dependency behaviour are unchanged, with no regression for descriptions that already use `blocked-by:tNNN`.
- [ ] An unresolvable `GH#NNN` does not break the TODO line; it is omitted with a warning.

## Verification

```bash
bash .agents/scripts/tests/test-claim-task-id-blocked-by-todo.sh
bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh
shellcheck .agents/scripts/claim-task-id-issue.sh .agents/scripts/claim-task-id.sh

```
