## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session)
- **Evidence source:** issue-sync run `37495532410` log; t18583 TODO entry and planning PR #33521; framework docs listed below

## What

Make the "save for later" guidance match what issue-sync actually does, and stop the
false task-ID collision warning on planning PRs.

1. Guidance says saved/later work is "a local TODO/plan without creating an implementation
   issue", but `issue-sync-helper.sh push` creates an issue for every open `- [ ] tNNN`
   TODO row without `ref:GH#` (`_push_build_task_list`,
   `.agents/scripts/issue-sync-helper-push.sh:55-67`), and the `/save-todo` "simple"
   template itself writes a `tNNN` row. Align the docs with the mechanics: an ID-bearing
   saved task becomes a **non-dispatched tracking issue** (no `auto-dispatch`); only the
   ID-less plan-line form (`- [ ] {title} #plan → [...]`) stays issue-less.
2. `_push_warn_if_task_id_collides` (`issue-sync-helper-push.sh:297-307`) matches any merged
   PR whose title contains the task ID, so every task's own planning PR (`tNNN: plan ...`)
   triggers `TASK ID COLLISION ... will be blocked by the dedup guard`. Ignore merged PRs
   whose title starts with `tNNN: plan` (or whose only changes are planning files).

## Why

t18583 was saved on 2026-10-04 as "deferred capability brief only; no implementation
issue" (#33521). Issue-sync then tried to create its issue on every push to `main`; that
attempt failed (privacy guard on a placeholder path), and the failure skipped planning
publication for all other tasks until 2026-10-06. Doc/mechanics mismatch led the author to
expect no issue; the false collision warning added misleading noise to the same log.

## Tier

`tier:standard` — doc wording in three files plus one small warning-filter change.

## How (Approach)

### Files to Modify

- `EDIT: .agents/reference/task-lifecycle.md:138` — "save/log/for later" row: saved `tNNN` tasks publish as tracking issues without `auto-dispatch`; ID-less plan lines stay local.
- `EDIT: .agents/scripts/commands/save-todo.md:16,55` — same wording; keep "do not ask to dispatch".
- `EDIT: .agents/workflows/brief.md:~182` — same wording where it says "keep the work as a local TODO/plan".
- `EDIT: .agents/scripts/issue-sync-helper-push.sh:297-307` — skip the collision warning when the matched merged PR title is the task's own planning PR (`^tNNN: plan`); reuse `_gh_find_merged_pr_evidence` (`issue-sync-helper-labels.sh:309`) or extend it with a title field.
- `EDIT: .agents/scripts/tests/test-issue-sync-push-failures.sh` or the nearest existing push suite — add one case for the planning-PR exemption (no new harness).

### Complete Write Surface

- **Callers/readers:** `_push_process_task` calls the collision warning; docs read by `/save-todo`, `/new-task`, brief workflow.
- **Writers/mutation paths:** none (warning only; docs).
- **Existing verification/tests:** `tests/test-issue-sync-push-failures.sh`, `tests/test-issue-sync-title-dedup.sh`.
- **Schemas/config:** none. **Migrations:** none. **Rollback:** revert.

### Hazards and Compatibility

- Real collisions (an implementation PR reusing the ID) must still warn.
- Do not change `.agents/AGENTS.md` beyond a pointer; keep the size ratchet.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-issue-sync-push-failures.sh
bash .agents/scripts/tests/test-issue-sync-title-dedup.sh
shellcheck .agents/scripts/issue-sync-helper-push.sh
.agents/scripts/linters-local.sh --changed
```

- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/reference/task-lifecycle.md`
- `.agents/scripts/commands/save-todo.md`
- `.agents/workflows/brief.md`
- `.agents/scripts/issue-sync-helper-push.sh`
- `.agents/scripts/tests/test-issue-sync-push-failures.sh`

## Acceptance Criteria

- [ ] Positive: docs state that saved `tNNN` tasks become non-dispatched tracking issues and ID-less plan lines stay local; no remaining doc claims an ID-bearing TODO row gets no issue.
- [ ] Positive: a task whose only merged PR is `tNNN: plan ...` produces no collision warning.
- [ ] Regression: a merged non-planning PR titled with the same task ID still warns.
- [ ] All verification commands pass.

## Context & Decisions

- Chosen: align docs with existing mechanics (tracking issue, no dispatch) over a new issue-less tag — maintainer chose this for t18583 on 2026-10-06; avoids a second publication path.
- Out of scope: privacy guard flags tilde-prefixed placeholder paths (home-relative `Git/<owner>/<repo>`) as local paths (`privacy-guard-helper.sh:389`). Treat as a separate finding only if it recurs.
