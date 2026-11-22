<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `non-closing reference closed issue zero diff PR close pulse` → 0 relevant hits.
- [x] Discovery pass: GH#38496 only labels and comments these PRs; no open issue or PR retires them (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:standard`. One merge-pass branch with head-pinned evidence reads.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** On 2026-11-19 an interactive session had to close three `marcusquinn/aidevops` PRs by hand, none of which any merge pass could land or retire. PR #39184 (worker) had an empty diff against main and linked completed issue #39098; pulse logged `skipping PR #39184 ... non-closing reference to issue #39098 which is not open (GH#33999)` 12 times. PRs #39138 and #39149 (interactive planning PRs) only added open `- [ ] tNNN ... #auto-dispatch` TODO rows for tasks whose issues #39136 and #39148 had already closed as completed, and both conflicted on TODO.md.

## What

When the merge pass meets a PR whose only issue reference is non-closing (`For`/`Ref`) to an issue that is closed with `state_reason: completed`, close the PR with an evidence comment in either of two cases:

1. **Zero diff:** `GET repos/{slug}/pulls/{n}/files` returns `[]` at the pinned head. Main already contains the change.
2. **Stale planning row:** every changed file is `TODO.md` or `todo/**/*.md`, and the diff only adds task rows and briefs for that closed issue's task. Merging would plant an open row for finished work.

All other cases keep today's GH#38496 behaviour: label, comment once, and exclude from the backlog count. Never close when the issue closed as `not_planned`/`duplicate` but the PR has a non-planning diff, or when the head moved between reads.

## Why

These PRs stay open forever. Pulse re-evaluates them on every merge pass, spending REST calls, and a human has to find and close them. That is user attention the system exists to save. Today's rate: 1 of 24 plan PRs closed unmerged and 2 left open in 7 days, plus one worker PR.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-merge-process-worker-briefed.sh:702-730` (`_worker_briefed_flag_not_open_reference`). Before labelling, read the linked issue's `state_reason` and the PR files at the pinned head (reuse the before/after head-binding in `_worker_briefed_pr_is_planning_checkpoint`, `:346-380`). Close on case 1 or case 2 with `gh pr close --comment`, matching `_pmp_close_superseded_sibling_pr` (`.agents/scripts/pulse-merge-duplicate-consolidation.sh:181-203`), and invalidate the PR list cache the same way.
- INVESTIGATE: the interactive-origin merge path (`.agents/scripts/pulse-merge.sh`, origin-interactive auto-merge). #39138/#39149 were `origin:interactive` and never received the GH#38496 label, so that path may need the same check. If no shared hook point exists, record that in the PR and handle only the worker-briefed path.

Touch `pulse-merge.sh` only if the interactive path needs the shared check. Extend the existing suite only where its fixtures already cover `_worker_briefed_flag_not_open_reference`.

### Files Scope

- `.agents/scripts/pulse-merge-process-worker-briefed.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh`

### Reference pattern

- Head-pinned file read: `_worker_briefed_pr_is_planning_checkpoint` (`pulse-merge-process-worker-briefed.sh:346`).
- Evidence-bearing close: `_pmp_close_superseded_sibling_pr` (`pulse-merge-duplicate-consolidation.sh:181`).

## Acceptance Criteria

- [ ] A worker PR with `For #N`, issue `#N` closed as completed, and an empty file list is closed by one merge pass with a comment citing the empty diff and the issue's close time.
- [ ] A TODO/todo-markdown-only PR whose added rows belong to a completed issue is closed. The same PR touching any other path is not closed and keeps the GH#38496 label behaviour.
- [ ] A head change between the file read and the close leaves the PR open (fail closed).
- [ ] `test-pulse-merge-worker-briefed.sh` passes and ShellCheck is clean for changed scripts.
