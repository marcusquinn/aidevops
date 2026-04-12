<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1984: sync-todo-to-issues workflow — auto-assign new issues to the pusher when origin is interactive

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up from t1970 and the t1979-t1981 filing)
- **Created by:** ai-interactive
- **Parent task:** t1970 (merged via PR #18374) — that PR added auto-assign to `issue-sync-helper.sh` but NOT to the server-side GitHub Actions workflow that also creates issues from TODO.md pushes.
- **Conversation context:** When I pushed TODO.md with three new entries during this session (t1979-t1981), both my local `issue-sync-helper.sh push` and the server-side `Sync TODO.md → GitHub Issues` workflow fired. The workflow won the race for t1980 and t1981, creating issues #18394 and #18395 — **without any assignee**. The t1970 fix (auto-assign `@me` when origin is interactive) applies only to the local script path, not to the workflow. Result: issues #18394 and #18395 started unassigned, which would have caused Maintainer Gate failures on any follow-up PRs if I hadn't manually self-assigned.

## What

Extend the `Sync TODO.md → GitHub Issues` GitHub Actions workflow so that when it creates a new issue from a TODO.md entry tagged `origin:interactive` (via the `#interactive` TODO hashtag), it also auto-assigns the issue to the pusher of the commit that triggered the workflow. Mirror the t1970 auto-assign logic from `issue-sync-helper.sh` into the workflow, using `${{ github.event.pusher.name }}` or `github.actor` as the assignee.

Worker-origin entries (`#worker` → `origin:worker`) remain untouched — they follow the pulse dispatch flow which has its own assignment semantics.

## Why

Interactive sessions hit Maintainer Gate failures whenever the server-side workflow creates an issue faster than the local `issue-sync-helper.sh push` can. The gate fails because the issue has no assignee at the time CI runs, and the failed check doesn't auto-retry when an assignee is added later.

Observed this session:

- **#18394 (t1980)** created by `Sync TODO.md → GitHub Issues` workflow on TODO.md push — assignees empty after creation, had to `gh issue edit --add-assignee @me` manually
- **#18395 (t1981)** same pattern — assignees empty after creation

Both would have blocked any downstream PR's Maintainer Gate. The local `issue-sync-helper.sh` path (PR #18374 / t1970) is fixed but only applies when the developer remembers to run it. The workflow runs unconditionally on every TODO.md push, which is the primary creation path in practice. Fixing only the local path leaves the common case broken.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 (`.github/workflows/issue-sync.yml` or equivalent; name TBD)
- [x] **Complete code blocks for every edit?** — yes, the logic is the same as t1970's — check origin label, add assignee via `gh issue edit` or the GitHub API step
- [x] **No judgment or design decisions?** — minor: whether to use `github.event.pusher.name` (from push event) or `github.actor` (whoever triggered the workflow). Both usually resolve to the same identity. `github.actor` is more portable across event types.
- [x] **No error handling or fallback logic to design?** — existing workflow error handling (skip on gh auth failure etc.) is preserved
- [x] **Estimate 1h or less?** — yes, ~45m
- [x] **4 or fewer acceptance criteria?** — 3

**Selected tier:** `tier:simple`

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/issue-sync.yml` (or the workflow that runs `issue-sync-helper.sh push` on TODO.md changes — locate via `rg -l "issue-sync-helper" .github/workflows/`)

### Investigation

1. Find the workflow that fires on TODO.md pushes:

    ```bash
    rg -l 'issue-sync-helper|sync.*todo.*github' .github/workflows/
    ```

2. Read the workflow to understand the existing issue creation step — is it a direct `gh issue create` call, or does it invoke `issue-sync-helper.sh push`?
   - If it invokes `issue-sync-helper.sh push`: **t1983 fix to `issue-sync-lib.sh` + t1970 fix already in `issue-sync-helper.sh` together handle this automatically** — the workflow picks up the fix on the next deploy. In that case, this task may be redundant with t1983.
   - If it uses direct `gh api` / `gh issue create`: the fix must go into the workflow YAML.

### Implementation Steps

Case A: workflow delegates to `issue-sync-helper.sh push` (expected):

1. Verify that `$AIDEVOPS_SESSION_ORIGIN` or equivalent is set in the workflow step's env so the helper's origin detection produces `origin:interactive`. If not set, add:

    ```yaml
    - name: Sync TODO → Issues
      env:
        AIDEVOPS_SESSION_ORIGIN: interactive  # or derive from commit message / TODO tags
      run: |
        .agents/scripts/issue-sync-helper.sh push
    ```

2. Verify `gh` CLI has sufficient token scopes (`issues:write`) in the workflow.

Case B: workflow uses direct `gh issue create`:

1. Add a post-create step:

    ```yaml
    - name: Auto-assign interactive-origin issues
      if: steps.sync.outputs.created_issue_numbers != ''
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        for num in ${{ steps.sync.outputs.created_issue_numbers }}; do
          gh issue edit "$num" --repo "${{ github.repository }}" \
            --add-assignee "${{ github.actor }}" || true
        done
    ```

Testing: push a dummy TODO entry with `#interactive` hashtag and verify the created issue has the pusher as assignee.

### Verification

```bash
# Create a throwaway branch, add a TODO entry, push
git checkout -b test/t1984-sanity
cat >> TODO.md <<'EOF'
- [ ] t9999 test task for t1984 verification #interactive ~5m tier:simple logged:2026-04-12 -> [todo/tasks/t9999-brief.md]
EOF
# Write a stub brief to satisfy the sync-helper's require-brief check
mkdir -p todo/tasks
printf '# t9999: test\n## What\ntest\n' > todo/tasks/t9999-brief.md
git add TODO.md todo/tasks/t9999-brief.md
git commit -m "test(t1984): sanity check"
git push -u origin test/t1984-sanity

# Wait for workflow to run, then verify
sleep 30
gh issue list --repo marcusquinn/aidevops --search "t9999 in:title" --json number,assignees

# Cleanup
gh issue close <number>
git push origin :test/t1984-sanity
git checkout main
git branch -D test/t1984-sanity
```

## Acceptance Criteria

- [ ] When a TODO.md entry tagged `#interactive` triggers the `Sync TODO.md → GitHub Issues` workflow, the created GitHub issue has an assignee matching `github.actor` (the pusher).
- [ ] Worker-origin entries (`#worker`) remain unassigned at creation (existing behaviour preserved — pulse dispatch handles their assignment).
- [ ] The workflow is idempotent: running it again on a TODO.md entry that already has `ref:GH#NNN` is a no-op, and running on one whose issue already has an assignee doesn't add duplicate assignees.

## Context & Decisions

- **Why not rely on t1970's fix alone:** t1970 fixed `issue-sync-helper.sh` in the repo. If the workflow invokes that script, the fix propagates on next deploy. But I need to verify the invocation path — it's possible the workflow uses direct `gh api` calls. The investigation step tells us which case we're in.
- **Why `github.actor` instead of `github.event.pusher.name`:** `github.actor` works across more event types (push, workflow_dispatch, pull_request) without branching. For TODO.md pushes specifically they're identical.
- **Why not auto-assign ALL issues (not just interactive):** worker-origin issues need to stay unassigned at creation so the pulse dispatch logic can claim them atomically via `status:queued` → `status:claimed`. Pre-assigning a worker issue would confuse the dispatcher.

## Relevant Files

- `.github/workflows/issue-sync.yml` (path TBD — find via rg)
- `.agents/scripts/issue-sync-helper.sh` — may already be invoked by the workflow; if so, t1970's fix propagates automatically and this task is mostly verification
- `.agents/scripts/issue-sync-lib.sh` — t1983's fix lives here

## Dependencies

- **Blocked by:** none (t1970 already merged)
- **Blocks:** reliable interactive-session PR flow when the server-side workflow wins the race
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Investigation | 15m | rg for workflow, read YAML |
| Implementation | 15m | Either case A (env var) or case B (post-create step) |
| Testing | 10m | sanity push + verify |
| PR | 5m | |

**Total estimate:** ~45m
