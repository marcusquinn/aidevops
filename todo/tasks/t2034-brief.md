---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2034: fix(issue-sync): add GH_TOKEN to Update TODO.md proof-log step

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (same session as t2015/t2018/t2027/t2028/t2029/t2030)
- **Created by:** marcusquinn (ai-interactive — direct follow-up after observing t2029's merge-run output)
- **Conversation context:** t2029 added a `gh pr comment` fallback to the `Update TODO.md proof-log` step in `issue-sync.yml` so users see a comment on the merged PR when the auto-completion push is rejected by branch protection. When t2029's own merge ran, the `::error::` workflow messages fired correctly (good — visible failure works) but the `gh pr comment` call silently failed because the step's `env` block doesn't set `GH_TOKEN`, so `gh` ran without auth credentials and printed nothing. Verified by inspecting `/tmp/t2029-merge-run.log` from run 24321411170. Two-line fix.

## What

The `Update TODO.md proof-log` step in `.github/workflows/issue-sync.yml` (around line 467) has `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` in its env block, so the t2029 `gh pr comment` fallback can authenticate and actually post the user-friendly comment.

## Why

Without GH_TOKEN, `gh pr comment` fails silently (no error, no exit code propagated) because the t2029 fallback wraps the call in `2>/dev/null || echo "::warning::Also failed..."`. The user only sees the `::error::` messages in the workflow log, not the friendly PR comment that was supposed to surface the manual command. The whole point of t2029 was to make the failure visible AND actionable — the actionable part needs GH_TOKEN.

## Tier

- [x] **≤2 files to modify?** — 1 file
- [x] **Complete code blocks?** — yes
- [x] **No judgment?** — well-known gh CLI auth requirement
- [x] **No fallback design?** — env addition only
- [x] **≤1h?** — ~5 minutes
- [x] **≤4 acceptance criteria?** — exactly 3

**Selected tier:** `tier:simple`

## How

### Implementation

In `.github/workflows/issue-sync.yml` Update TODO.md proof-log step (around line 467), add `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` to the env block:

```yaml
      - name: Update TODO.md proof-log
        if: steps.extract.outputs.task_id != ''
        env:
          TASK_ID: ${{ steps.extract.outputs.task_id }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          # t2034: gh CLI needs GH_TOKEN explicitly — without it, the t2029
          # `gh pr comment` fallback (posted when the TODO.md push is rejected
          # by branch protection) silently fails because gh has no auth.
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
```

### Verification

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/issue-sync.yml'))"
grep -A1 "t2034: gh CLI" .github/workflows/issue-sync.yml | grep "GH_TOKEN"
```

Runtime verification: the next merge that hits the branch-protection wall should produce both (a) the workflow `::error::` messages AND (b) a PR comment containing the manual `task-complete-helper.sh` command.

## Acceptance Criteria

- [ ] `Update TODO.md proof-log` step has `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` in its env block.
  ```yaml
  verify:
    method: codebase
    pattern: "t2034: gh CLI needs GH_TOKEN"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/issue-sync.yml\"))'"
  ```
- [ ] Runtime: the next failed-push merge produces a visible PR comment from the t2029 fallback. (Manual verification on next applicable merge.)
  ```yaml
  verify:
    method: manual
    prompt: "On the next merged PR where the TODO.md push fails (branch protection), confirm a PR comment with the t2029:auto-complete-blocked marker was posted by github-actions[bot]."
  ```

## Context & Decisions

**Why an env-level addition rather than a script-level workaround.** `gh` reads `GH_TOKEN` (and `GITHUB_TOKEN` as fallback) from env. The cleanest fix is to expose it where the step runs. Wrapping `gh pr comment` in `GH_TOKEN=... gh pr comment` would also work but is uglier and only fixes one call site.

**Why the previous step (`Apply closing hygiene to linked issues`) doesn't have this problem.** It DOES set `GH_TOKEN` in its env block (you can verify at line ~370). The Update TODO.md step was missing it because it didn't originally need to call `gh` — it only ran `git push`. t2029 added the `gh pr comment` call but didn't update the env block.

**Non-goals:** rewriting the t2029 fallback, changing the comment body, fixing branch protection itself.

## Relevant Files

- `.github/workflows/issue-sync.yml:467-475` — the env block to extend.
- `.github/workflows/issue-sync.yml:507-563` — the t2029 fallback that needs GH_TOKEN to work.

## Dependencies

- **Blocked by:** none (t2029 is already merged, this is a follow-up fix)
- **Blocks:** nothing hard. Without this fix, t2029's PR comment fallback never lands.
- **External:** none

## Estimate

| Phase | Time |
|-------|------|
| Implementation | 3m |
| Lint + verify | 2m |
| **Total** | **~5m hands-on + ~15m CI** |
