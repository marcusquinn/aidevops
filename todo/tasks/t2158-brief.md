---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2158: Cross-check TODO.md historical IDs in claim-task-id.sh to prevent collisions

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:t2153-followup
- **Created by:** ai-interactive (marcusquinn directing)
- **Parent task:** none
- **Conversation context:** While filing t2156/t2157, `claim-task-id.sh` allocated `t2155` from the `.task-counter` file (which was at 2155). Discovered post-claim that `t2155` was already used and `[x] completed` on 2026-04-02 (PR #15580/#15581, GH#15042). The counter and TODO.md had drifted — counter advanced past historical entries. The t2047 `task-id-collision-check.yml` workflow guards _commit subjects_ against collisions, but does NOT check that `claim-task-id.sh` itself allocates IDs that don't already exist as historical TODO entries. Resulted in a burnt task ID (no harm done, ID skipped), but in a less-careful workflow could have caused brief overwrite or audit-trail corruption.

## What

`claim-task-id.sh` MUST cross-check that the proposed `tNNN` ID does not already appear in `TODO.md` as a historical entry (`- [x] tNNN ...` or `- [ ] tNNN ...`) before committing the counter advance. On collision, the script MUST skip the colliding ID (advance counter past it) and re-attempt with the next free value. Maximum skip-ahead distance: 100 IDs (defensive bound; if 100 sequential IDs all collide, abort with an error and surface the .task-counter / TODO.md inconsistency for manual investigation).

Behavior contract: after a successful `claim-task-id.sh` invocation, the returned `task_id` MUST be guaranteed not to appear anywhere in `TODO.md` as `- [x] <id>` or `- [ ] <id>` at the time of the call.

## Why

Without this check, `claim-task-id.sh` can allocate IDs that already have completed work, briefs, and PR references. The danger surface includes:
- Brief overwrite (`todo/tasks/tNNN-brief.md` from a completed task gets clobbered by a new draft)
- TODO entries with duplicate IDs (one `[x]` historical, one `[ ]` new) — which the parent-task tracker, completion stats, and dispatch dedup all silently misinterpret
- Confusion in PR titles (`tNNN: ...` referencing the wrong task)
- Worker briefs pulled from the wrong file

The Apr 2 t2155 collision in this session burned the ID without harm because I caught it manually. The next collision could be silently destructive — a worker dispatched to "implement t2155 per brief" reading the wrong brief, with no diagnostic trail.

The `.task-counter` file is `2157` while `TODO.md` contains a historical `t2155`. This kind of drift WILL recur whenever:
- Manual TODO entries are added without using `claim-task-id.sh`
- Counter file is reset/restored from backup independent of TODO.md
- Multi-runner coordination misses a counter sync

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Likely 1 (claim-task-id.sh) + regression test
- [ ] **Every target file under 500 lines?** `claim-task-id.sh` is ~300 lines (check)
- [ ] **Exact `oldString`/`newString` for every edit?** Need to add a `_collision_check_against_todo()` helper + integrate into the claim loop
- [x] **No judgment or design decisions?** Behavior is mechanical (grep TODO.md, advance, retry)
- [x] **No error handling or fallback logic to design?** Bound at 100 retries, then abort with explicit error
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** Yes
- [x] **4 or fewer acceptance criteria?** Yes

**Selected tier:** `tier:standard`

**Tier rationale:** Single-file change with clear mechanical logic, plus regression test. Edge cases (counter behind/ahead of TODO.md, max-skip bound) need careful handling but no novel design. The existing `claim_task_id_atomic()` git-CAS loop is the integration point — extend it, don't invent new control flow.

## PR Conventions

Leaf task, use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- **EDIT:** `.agents/scripts/claim-task-id.sh` — add `_id_exists_in_todo()` helper that greps TODO.md for `- \[.\] tNNN ` (with the trailing space to disambiguate from prefix matches like t2155 vs t21551). Integrate into the claim loop: after computing the proposed `next_id`, call `_id_exists_in_todo`; if it returns 0 (collision), advance counter and retry up to 100 times before aborting.

- **NEW:** `.agents/scripts/tests/test-claim-task-id-collision.sh` — regression test that creates a sandbox `TODO.md` with a known collision (e.g. preseed `- [x] t9001 ...`), seeds `.task-counter` to 9001, runs `claim-task-id.sh --no-issue`, and asserts the returned ID is `t9002` (skipped past collision) and that `.task-counter` ends at 9003.

### Implementation Steps

1. **Add the collision helper.** In `claim-task-id.sh`:
   ```bash
   # Returns 0 if ID exists in TODO.md (collision), 1 if free.
   _id_exists_in_todo() {
     local task_id="$1" todo_file="${2:-TODO.md}"
     [[ -f "$todo_file" ]] || return 1
     grep -qE "^- \[[ x]\] ${task_id} " "$todo_file"
   }
   ```

2. **Integrate into the claim loop.** Find the loop that computes `next_id` and writes the counter. Wrap the assignment with a skip-and-retry. Pseudo-code (adapt to actual structure):
   ```bash
   local skip_count=0
   while _id_exists_in_todo "$next_id" "$todo_file"; do
     ((skip_count++))
     if (( skip_count > 100 )); then
       print_error "100 sequential ID collisions starting at $next_id — counter/TODO.md drift"
       print_error "Manual investigation required. Last known free ID: t$((next_id_num - 1))"
       return 2
     fi
     ((next_id_num++))
     next_id="t${next_id_num}"
   done
   ```

3. **Log skipped IDs.** When at least one skip occurs, log: `print_info "Skipped N already-used IDs starting at tNNN (collision recovery)"`. This makes drift visible.

4. **Update commit message.** Currently `chore: claim t2155`. After this fix, when collisions are skipped, the commit message should still be `chore: claim t2157` (the actual claimed ID), and the counter advance reflects all skipped IDs (so a follow-up `git log .task-counter` shows the +N jump).

5. **Regression test.** Create `tests/test-claim-task-id-collision.sh`:
   - Set up a temp directory with a stub `.task-counter` and `TODO.md` containing `- [x] t9001 stale entry @ai`
   - Source `claim-task-id.sh` (or invoke as subprocess with `cd $tmp_dir`)
   - Assert: after `claim-task-id.sh --no-issue --title "test"`, the returned ID is `t9002` (not `t9001`)
   - Assert: `.task-counter` ends at `9003`
   - Variant: preseed `- [x] t9001`, `- [x] t9002`, `- [x] t9003` and counter at 9001 → expect returned `t9004`, counter at `9005`
   - Edge: 101 sequential collisions → expect non-zero exit and clear error message

### Verification

```bash
# 1. Regression test passes
bash .agents/scripts/tests/test-claim-task-id-collision.sh
# Expect: all assertions pass

# 2. ShellCheck clean
shellcheck .agents/scripts/claim-task-id.sh
shellcheck .agents/scripts/tests/test-claim-task-id-collision.sh

# 3. Live dry-run sanity (in this session's worktree, NOT main)
# Verify the helper correctly identifies the t2155 collision that triggered this task
grep -qE "^- \[[ x]\] t2155 " /Users/marcusquinn/Git/aidevops/TODO.md && echo "Would block t2155"
# Expect: prints "Would block t2155"
```

## Acceptance Criteria

- [ ] `_id_exists_in_todo()` helper added to `claim-task-id.sh`
- [ ] Claim loop skips collisions and advances counter accordingly
- [ ] Defensive bound (100 max skips) with clear error message on exceed
- [ ] Skipped collisions are logged via `print_info`
- [ ] Regression test covers: no collision, single skip, multiple sequential skips, max-skip-exceeded abort
- [ ] ShellCheck clean

## Context

- **Triggering incident:** This session, 01:38 BST — `claim-task-id.sh` returned `t2155` from counter 2155, but `TODO.md:2143` had `[x] t2155 simplification: tighten agent doc API Integration Guide ... ref:GH#15042 ... pr:#15580 pr:#15581 completed:2026-04-02`. The completed brief at `todo/tasks/t2155-brief.md` (Apr 4) was nearly overwritten until the collision was caught manually.
- **Related guard:** `.github/workflows/task-id-collision-check.yml` (t2047) — checks commit subjects, not allocator output. This task complements that guard.
- **Related counter logic:** `claim-task-id.sh` lines 60-73 already handle "bootstrap from TODO.md highest ID" on missing `.task-counter` — but only on missing, not on every claim. Extending to per-claim verification is the natural extension.
- **Counter state at filing:** `.task-counter` = 2159 (after t2155 burnt + t2156 + t2157 + t2158 claimed).
