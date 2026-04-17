---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2157: Skip auto-assignment in issue-sync-helper when #auto-dispatch tag is present

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:t2153-followup
- **Created by:** ai-interactive (marcusquinn directing)
- **Parent task:** none
- **Conversation context:** While clearing zombie state from the t1999-t2009 backlog batch (issues #19432-#19444), discovered that issue-sync-helper.sh auto-assigns the TODO pusher AND applies `origin:interactive` for newly-synced TODO entries. When the entry has `#auto-dispatch` (worker-intended), the auto-assignment creates the dispatch-blocking combo (`origin:interactive` + assigned + active status) per the GH#18352 / t1996 dedup rule, blocking pulse dispatch indefinitely until manually released. Found 3 zombies blocked this way (#19435, #19438, #19443); manually released them with `gh issue edit --remove-assignee`. The contradiction is logical: the user said "let a worker handle it" (`#auto-dispatch`) but the sync immediately took the assignment back.

## What

`issue-sync-helper.sh::_push_create_issue()` MUST skip the `origin:interactive` auto-assignment when the task's labels include `auto-dispatch`. The intent of `auto-dispatch` is to delegate to workers; auto-assigning the pusher contradicts that intent and creates the exact dispatch-blocking combo the t1996 dedup rule treats as a hard "do not dispatch" signal.

After the fix, a TODO entry like `- [ ] t9999 Fix the foo @ai #auto-dispatch ref:GH#NNNN` synced by issue-sync MUST result in: `origin:interactive` label applied (creation-context truth), `auto-dispatch` label applied, BUT no assignee on the issue. The pulse's deterministic-fill-floor will then dispatch a worker on the next cycle.

## Why

Every TODO entry pushed with `#auto-dispatch` from an interactive session today gets immediately self-blocked by the sync. The user has to either:
1. Notice the zombie and manually `gh issue edit --remove-assignee` (current state: 3 zombies in this batch alone)
2. Wait for `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` (24h default) for the t2148 normalize_active_issue_assignments safety net to clear it

Both are unacceptable for a tag whose entire purpose is "dispatch ASAP". The bug is invisible until the user notices issues are stuck — there is no error, no log, no signal beyond "why is this not progressing?".

The dispatch-blocking combo this creates is correct per t1996 (`origin:interactive` + assignee = active interactive claim) — the bug is that the sync emits this combo against the user's stated intent.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Likely 1 (issue-sync-helper.sh) plus a regression test
- [ ] **Every target file under 500 lines?** issue-sync-helper.sh is 2192 lines (large-file gate concern)
- [x] **Exact `oldString`/`newString` for every edit?** Yes — narrow conditional change at line 618
- [x] **No judgment or design decisions?** Yes — single condition added, behavior is mechanical
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** Yes
- [x] **4 or fewer acceptance criteria?** Yes

**Selected tier:** `tier:standard`

**Tier rationale:** Single conditional addition + regression test. Would be tier:simple except issue-sync-helper.sh is 2192 lines (>500 line disqualifier), and the change is in a hot path that touches every TODO push so caution warranted. The large-file gate (`scoped-range pass`) will allow this since the edit is localized to a ~20 line window.

## PR Conventions

Leaf task, use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- **EDIT:** `.agents/scripts/issue-sync-helper.sh:618-636` — add an `auto-dispatch` short-circuit before the auto-assignment block. The labels list (`$labels` parameter) and the computed `$all_labels` are both in scope at this point — use `$all_labels` since it's the canonical post-merge label set.

- **NEW:** `.agents/scripts/tests/test-issue-sync-auto-dispatch-skip.sh` — regression test verifying that a synthetic `_push_create_issue` invocation with `auto-dispatch` in the label list does NOT trigger the `gh issue edit --add-assignee` call. Mock pattern: model on `tests/test-stale-recovery-age-floor.sh` (uses sourced helper + stub functions for `gh`, `gh_create_label`, `gh_find_issue_by_title`).

### Implementation Steps

1. **Add the skip condition.** At line 618 of `issue-sync-helper.sh`, change:
   ```bash
   if [[ -n "$num" && -z "$assignee" && "$origin_label" == "origin:interactive" ]]; then
   ```
   to:
   ```bash
   if [[ -n "$num" && -z "$assignee" && "$origin_label" == "origin:interactive" ]] \
       && [[ ",${all_labels}," != *",auto-dispatch,"* ]]; then
   ```
   (The `,...,` framing prevents prefix-match false positives; mirrors the existing pattern at line 247 `parent-task | meta | auto-dispatch)`.)

2. **Add a log line for the skipped case.** Right after the closing `fi` of the new conditional, add an `else` branch (or inline `print_info` before the conditional) that logs:
   ```bash
   print_info "Skipped auto-assign for #${num} — #auto-dispatch present (worker-intended)"
   ```
   This makes the deviation visible in `~/.aidevops/logs/issue-sync.log` for future diagnosis.

3. **Document the new behavior in AGENTS.md.** Under "Auto-Dispatch and Completion" → "Session origin labels", add a sentence: "When `#auto-dispatch` is present, the issue is created with `origin:interactive` (truthful creation context) but is NOT auto-assigned to the pusher — the worker dispatch flow handles the claim."

4. **Regression test.** Create `tests/test-issue-sync-auto-dispatch-skip.sh`:
   - Source `issue-sync-helper.sh` (or extract `_push_create_issue` to a sourced lib)
   - Stub `gh`, `gh_create_label`, `gh_find_issue_by_title` to return canned values
   - Stub `gh issue edit --add-assignee` to record whether it was called
   - Assert: with `auto-dispatch` in labels, `--add-assignee` is NOT called
   - Assert: without `auto-dispatch` in labels, `--add-assignee` IS called

### Verification

```bash
# 1. Unit test passes
bash .agents/scripts/tests/test-issue-sync-auto-dispatch-skip.sh
# Expect: all assertions pass

# 2. ShellCheck clean
shellcheck .agents/scripts/issue-sync-helper.sh
shellcheck .agents/scripts/tests/test-issue-sync-auto-dispatch-skip.sh

# 3. End-to-end smoke test (in a worktree, not main)
# Add a test TODO entry with #auto-dispatch, push, verify the synced issue has no assignee
echo "- [ ] t9998 Test sync skip @ai #auto-dispatch" >> TODO.md
git add TODO.md && git commit -m "test: t2156 e2e verification" && git push
sleep 30
gh issue list --repo marcusquinn/aidevops --search "t9998 Test sync skip" --json number,assignees
# Expect: assignees empty array
# Cleanup: revert TODO entry, close test issue
```

## Acceptance Criteria

- [ ] `_push_create_issue` skips `--add-assignee` when `auto-dispatch` is in `$all_labels`
- [ ] Behavior is preserved (auto-assign still fires) for `origin:interactive` entries WITHOUT `auto-dispatch`
- [ ] Skipped case logs an `[INFO]` line to `~/.aidevops/logs/issue-sync.log`
- [ ] Regression test in `.agents/scripts/tests/test-issue-sync-auto-dispatch-skip.sh` covers both branches
- [ ] AGENTS.md updated under "Session origin labels" with the new behavior

## Context

- **Stored memory:** `mem_20260417013742_179ff3a8` — full pattern diagnosis
- **Affected issues this session:** #19435, #19438, #19443 — all manually released at 01:38 BST
- **#19443 anomaly:** had BOTH `origin:interactive` AND `origin:worker` labels — separate sync drift bug, may need follow-up if it recurs
- **Related rules:** `t1996` (combined dedup signal), `GH#18352` (interactive + assignee blocks dispatch), `t2148` (24h normalize_active_issue_assignments safety net which is currently the only recovery path for this bug)
- **Code reference:** the original t1970/t1984 comments at lines 603-617 explain WHY auto-assign was added (race against Maintainer Gate workflow). For `#auto-dispatch` tasks the maintainer-gate concern is irrelevant — the worker dispatch flow handles approval/labels.
