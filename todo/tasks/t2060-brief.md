<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2060: fix(task-complete-helper) — move completed entries from `## Ready` to `## Done` in TODO.md

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:feature-gh18538-worker-is-triager
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — (orthogonal cleanup surfaced by GH#18538)
- **Conversation context:** While diagnosing GH#18538, we discovered ~20+ completed `[x]` entries (t1969, t1970, t1981, t1983, t1984, t1985, t1986, t1990, t1992, t1995, t1998, t2015, t2018, t2028, t2029, t2030, t2032, t2033, t2034, ...) sitting in the `## Ready` section of `TODO.md`. Root cause: `task-complete-helper.sh:353` marks tasks `[ ]` → `[x]` *in place* via sed and never moves the entry. The original Gemini bot finding on PR #18417 was wrong about the *mechanism* (it thought `## Ready` was auto-generated and overwriteable, which it is not — `todo-ready.sh` is read-only) but right about the *symptom*: completed tasks should live in `## Done`.

## What

Two parts:

1. **Behavior change.** Modify `complete_task()` in `.agents/scripts/task-complete-helper.sh` to extract the matched task line from its current location and insert it at the top of the `## Done` section instead of doing in-place sed substitution. Subtask handling (indented child entries under a parent) must move *with* the parent — they form a contiguous block ending at the next blank line.

2. **One-time retroactive cleanup.** Move all currently-completed `[x]` entries that live in `## Ready` (or `## Backlog`) into `## Done`. This is a one-off TODO.md edit committed in the same PR. Approximately 20-30 entries; preserve their existing fields (proof-log, dates, tags, indentation).

## Why

- **Convention drift:** the file structure `## Ready / ## Backlog / ## In Progress / ## In Review / ## Done` exists for a reason. `## Done` should actually hold done items. Twenty completed entries in `## Ready` make `/ready`-style queries noisy and bot reviews of TODO.md misleading.
- **Bot noise reduction:** Gemini's wrong premise on PR #18417 happened *because* it saw a completed entry in `## Ready` and reasoned about overwrites. With completed entries living in `## Done`, that class of bot finding stops being plausible.
- **Single source of truth:** `task-complete-helper.sh` is the canonical completion path (commit-msg hook + manual + `sync-on-pr-merge` workflow all funnel through it). One fix here cleans up the future automatically.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** (`task-complete-helper.sh` + `TODO.md`)
- [ ] **Complete code blocks for every edit?** — partial; the awk/sed for the move logic is non-trivial and the worker must design it
- [x] **No judgment or design decisions?** — minor: where to insert in `## Done` (top vs bottom)
- [x] **No error handling or fallback logic to design?** — must preserve existing rollback (`mv .bak`)
- [x] **Estimate 1h or less?** — closer to 1.5-2h with tests
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** Bash awk/sed manipulation of a structured markdown file with subtask handling, idempotency, indentation preservation, and bash 3.2 portability constraints. Test harness needed. Sonnet handles this comfortably; haiku would struggle with the awk state machine.

## PR Conventions

Leaf task — use `Resolves #18746` in the PR body.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/task-complete-helper.sh:279-378` — replace in-place sed with extract-and-move logic.
- `EDIT: TODO.md` — one-off retroactive move of ~20-30 completed entries from `## Ready` to top of `## Done`.
- `NEW: .agents/scripts/tests/test-task-complete-move.sh` — regression harness (model on `tests/test-privacy-guard.sh` for stub style).

### Implementation Steps

**Step 1 — Read the current `complete_task()` function** (`task-complete-helper.sh:279-378`). Note: it currently does subtask validation, then a sed in-place replacement at line 353, then verifies the result. The new version must preserve all the validation logic and add the move.

**Step 2 — Replace the in-place sed with an extract-and-insert block.** The new flow:

```bash
# After all subtask guards have passed and proof_log is ready:

today=$(date +%Y-%m-%d)
cp "$todo_file" "${todo_file}.bak"

# 1. Find the line number of the parent task entry (top-level `- [ ] tNNN`).
# 2. Find the end of the entry's block: walk forward until next blank line OR
#    next top-level "- [ ]" / "- [x]" entry at column 0.
# 3. Capture the block (parent + indented children) into a variable.
# 4. Transform the parent's "[ ]" -> "[x]" and append "${proof_log} completed:${today}".
# 5. Locate the "## Done" header line.
# 6. Insert the transformed block at line `done_header + 2` (immediately under the header,
#    after the existing blank line that follows the heading per markdown convention).
# 7. Delete the original block from its old location.
# 8. Verify with the existing post-edit grep checks.
# 9. On any failure: mv "${todo_file}.bak" back.
```

The cleanest implementation is a single `awk` pass that streams TODO.md, identifies the source block, buffers it, transforms it, and emits everything except the source block — then a second pass inserts the buffered block under `## Done`. Bash 3.2 portable (no associative arrays, no `${var,,}`).

Critical edge cases to test:

- Task with no subtasks (single line)
- Task with explicit subtask IDs (`t123.1`, `t123.2`) — these are part of the block
- Task with indentation-based subtasks (children at deeper indent)
- Task already in `## Done` — should be a no-op (idempotent), warn and exit 0
- Task in `## In Progress` or `## In Review` — also gets moved to `## Done`
- `## Done` header missing — error out clearly, do not invent it
- Multiple consecutive `[ ] tNNN` entries — make sure the block boundary detection doesn't bleed into the next entry

**Step 3 — Retroactive cleanup of TODO.md.** After the helper change is verified working, run it (or the equivalent move logic) against every existing `[x]` entry currently in `## Ready` or `## Backlog`. Or use a one-shot script:

```bash
# In a worktree only:
for tid in $(grep -oE '^\s*- \[x\] t[0-9]+' TODO.md | awk '{print $3}'); do
  # Skip if already in the Done section (idempotent check)
  ...
done
```

Alternatively: since this is a one-time edit, do it manually by extracting the lines under `## Ready` matching `^- \[x\]` (and their immediately-following indented continuation lines), removing them, and prepending them to `## Done`. Verify with a diff that no entries were lost or duplicated and that line counts add up.

**Step 4 — Test harness.** Create `tests/test-task-complete-move.sh` modeled on `tests/test-privacy-guard.sh`:

- Set up a fake repo with a fixture TODO.md that has all the section headers and a few open tasks.
- Run `task-complete-helper.sh tNNN --pr 123 --no-push --skip-merge-check` for each test case.
- Assert: the entry no longer appears in its original section, appears in `## Done`, has the proof-log appended, and subtasks moved with it.
- Cover all 7 edge cases above with separate fixtures.

### Verification

```bash
# Lint
shellcheck .agents/scripts/task-complete-helper.sh
shellcheck .agents/scripts/tests/test-task-complete-move.sh

# Test harness passes
bash .agents/scripts/tests/test-task-complete-move.sh

# Retroactive cleanup left zero [x] entries in Ready
awk '/^## Ready/{f=1; next} /^## /{f=0} f && /^- \[x\]/' TODO.md | wc -l | xargs test 0 -eq

# Done section grew by the right amount (sanity check)
grep -c '^- \[x\]' TODO.md  # should be unchanged total
```

## Acceptance Criteria

- [ ] `complete_task()` in `task-complete-helper.sh` moves the entry to `## Done` instead of in-place edit.
  ```yaml
  verify:
    method: codebase
    pattern: "## Done|done_header|insert.*done"
    path: ".agents/scripts/task-complete-helper.sh"
  ```
- [ ] Test harness `tests/test-task-complete-move.sh` exists and passes for all 7 edge cases.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-task-complete-move.sh"
  ```
- [ ] After retroactive cleanup, zero `[x]` entries remain in the `## Ready` or `## Backlog` sections of TODO.md.
  ```yaml
  verify:
    method: bash
    run: "awk '/^## Ready|^## Backlog/{f=1; next} /^## /{f=0} f && /^- \\[x\\]/' TODO.md | wc -l | xargs test 0 -eq"
  ```
- [ ] Total `[x]` entry count in TODO.md before and after the cleanup is identical (no entries lost or duplicated).
  ```yaml
  verify:
    method: manual
    prompt: "Diff TODO.md before and after the retroactive move and confirm `grep -c '^- \\[x\\]' TODO.md` is unchanged."
  ```
- [ ] shellcheck clean on both modified scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/task-complete-helper.sh .agents/scripts/tests/test-task-complete-move.sh"
  ```

## Context & Decisions

- **Insert at top of `## Done`, not bottom.** Top is chronologically newest-first, matches how readers scan the file. The existing `## Done` section happens to be sorted oldest-first today, but that's incidental — and inserting at the top is cheaper than appending at the end (no need to find the section's terminator).
- **One PR for both behavior change and retroactive cleanup.** Splitting them creates a window where the new helper fails on entries that were never moved manually, or where the manual cleanup gets undone by the next completion. Atomic is safer.
- **Don't rewrite the in-place validation logic.** All the existing subtask checks (explicit IDs, indentation-based, parent guards) stay intact — only the final edit step changes. This minimizes regression risk.
- **Bash 3.2 compat.** The repo is macOS-default (build.txt rule). No `${var,,}`, no `local -n`, no associative arrays without a guard. The awk solution is portable.
- **What we're NOT doing:** changing the section structure, adding a new section, or touching `todo-ready.sh`. Out of scope.

## Relevant Files

- `.agents/scripts/task-complete-helper.sh:279-378` — `complete_task()` function to modify.
- `.agents/scripts/task-complete-helper.sh:353` — the in-place sed line being replaced.
- `TODO.md:83` — `## Ready` header.
- `TODO.md:2167` (or wherever it is now) — `## Done` header.
- `.agents/scripts/tests/test-privacy-guard.sh` — model for the test harness style (stub-based, fixture-driven).
- `.agents/scripts/tests/test-issue-sync-lib.sh` — another model with similar awk/sed-on-TODO patterns.

## Dependencies

- **Blocked by:** none
- **Blocks:** none — but unblocks future bot reviews of TODO.md producing meaningful results.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Read current `complete_task()` + an existing TODO-mutating helper for awk patterns |
| Implementation | 50m | Replace sed with extract-and-insert; write awk block |
| Retroactive cleanup | 15m | One-off TODO.md move, verified by entry-count diff |
| Testing | 30m | New test harness with 7 edge cases |
| **Total** | **~1.75h** | |
