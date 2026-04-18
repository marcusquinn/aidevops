<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2245: detect stuck 3-way merge state in canonical repo on session start

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19763
**Tier:** standard (NOT auto-dispatch — research phase first)

## What

Research + detection task. During PR #19758 post-merge cleanup, the canonical `~/Git/aidevops` repo was found in a stuck 3-way merge state on `.agents/plugins/opencode-aidevops/provider-auth.mjs` — 1105-line diff, unmerged stages 1/2/3 in the index, but no active `MERGE_HEAD` / `REBASE_HEAD` / interactive operation. HEAD was correct (`cac55bd61 t2228: ... (#19758)`, matching `origin/main`); only the index held the conflict.

Clean-up via `git reset --hard HEAD` was safe (HEAD = origin/main) but the STATE was pre-existing — not introduced by the t2228 lifecycle session. Unknown who/what left the canonical in this state.

## Why

1. A canonical repo with a UU index silently blocks `git pull --ff-only` on session start, which can cascade into failed hot-fix workflows and routine automation.
2. `aidevops-update-check.sh` session-start routine does NOT currently detect or warn about this state.
3. Repeat occurrence is likely — we don't know the trigger — so a detection + advisory hook is worth more than a one-off manual fix.

## How

### Phase 1 — Investigate (research, ~1-2h)

- Check reflog for `HEAD` + `main` + the conflicting file across all aidevops worktrees for any partial merge/pull/rebase that bailed out without unstaging.
- Review scripts that may run `git merge` or `git cherry-pick` in the canonical without transaction discipline:
  - `.agents/scripts/version-manager.sh`
  - `.agents/scripts/full-loop-helper.sh` (merge path)
  - `.agents/scripts/headless-runtime-helper.sh`
  - `.agents/scripts/pulse-merge.sh`
  - `.agents/scripts/pulse-issue-reconcile.sh`
- Look for `git merge ...` / `git cherry-pick ...` / `git apply --index` paths that don't have error handlers to `git reset --hard HEAD` or `git merge --abort` on failure.
- Check whether localdev/branch-route teardown (e.g., `worktree-helper.sh remove` → localdev integration) touches the canonical.
- Document findings in this brief as an "Investigation Notes" section before moving to Phase 2.

### Phase 2 — Detection (implementation, ~30min)

- **EDIT:** `.agents/scripts/aidevops-update-check.sh` — add `_detect_stuck_index_conflict()` function.
  - Called from the existing session-start advisory pipeline.
  - Runs `git -C <canonical-path> ls-files --unmerged` on each registered repo in `repos.json`.
  - Non-empty output → emit a session-greeting advisory listing the file(s) and recommended clean-up:
    - First step: `git -C <path> status` to see the conflict
    - Second step: `git -C <path> rev-parse HEAD` vs `origin/main` — if match, safe to `git reset --hard HEAD`; if not, manual inspection required
- Advisory goes through `~/.aidevops/advisories/` pipeline so user can dismiss it with `aidevops security dismiss <id>`.

### Phase 3 — Prevention (optional, blocked on Phase 1 findings)

- Audit scripts identified in Phase 1 for missing error handlers.
- Add `git merge --no-commit` + explicit abort-on-any-error pattern to any script that performs merges in the canonical.
- File as a separate task once Phase 1 identifies concrete offenders.

### Files to modify

- Phase 2 primary: `.agents/scripts/aidevops-update-check.sh`
- Phase 3: TBD based on Phase 1 findings

### Verification

- Manual repro: create a fake stuck index on a scratch worktree (e.g., start a merge with known conflict, don't commit, don't abort, clear `MERGE_HEAD`). Session-start check emits advisory naming the file.
- False-positive check: clean canonical → no advisory.
- `shellcheck .agents/scripts/aidevops-update-check.sh` clean.

### Why NOT auto-dispatch

Phase 1 is pure investigation with no deterministic implementation — a worker would waste tokens guessing at the root cause. Once Phase 1 identifies the trigger, Phase 2 is tier:simple and Phase 3 becomes a distinct follow-up task per offender.

## Acceptance Criteria

- [ ] Phase 1 findings documented (root cause OR "could not reproduce, adding detection anyway")
- [ ] `aidevops-update-check.sh` detects unmerged index state in canonical repos
- [ ] Advisory includes the conflicting file list + safe remediation
- [ ] No false positives on clean canonical
- [ ] ShellCheck clean

## Context

Discovered during PR #19758 (t2228 v3.8.71 lifecycle retrospective) — bonus find #4 of 4. Lowest confidence of the four: possible one-off, but detection is cheap insurance.
