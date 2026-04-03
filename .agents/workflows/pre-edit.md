---
mode: subagent
tools:
  bash: true
---
# Pre-Edit Git Check

Run before any file edits:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Safe to edit | Proceed |
| `1` | On `main`/`master` | STOP — present prompt below, WAIT for reply |
| `2` | Loop mode needs worktree | Auto-create worktree |
| `3` | Feature branch in main repo | Present exit-3 options below |

**Exit 1 prompt:**
> On `main`. Suggested branch: `{type}/{suggested-name}`
> 1. Create worktree (recommended)
> 2. Use different branch name
> 3. Stay on `main` (docs-only)

**Exit 3 prompt:**
> On branch: `{branch}` (main repo, not worktree)
> 1. Create worktree for this task (recommended)
> 2. Continue on current branch
> 3. Switch to `main`, then create worktree

## Loop Mode Keywords

- **Docs-only** (`readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`) → stay on `main`
- **Code** (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`) → create worktree; code keywords override docs keywords

## Worktree Default

Keep `~/Git/{repo}/` on `main`. Avoids blocked branch switches, parallel sessions inheriting the wrong branch, and `local changes would be overwritten` errors.

Stay on `main` only for: docs-only changes (README, CHANGELOG, `docs/`), typos, version bumps, planning files (`TODO.md`, `todo/`). Planning-file commits use `planning-commit-helper.sh "plan: add new task"`.

| Scenario | Script output | Action |
|----------|---------------|--------|
| In worktree | `OK - On branch: X (in worktree)` | Proceed |
| In main repo | `WARNING - MAIN REPO ON FEATURE BRANCH` | Present exit-3 options |

Continuing on the current branch is acceptable only when the task matches the branch purpose, will be finished in this session, and no parallel sessions are expected.

## Worktree Creation

```bash
wt switch -c {type}/{name}
~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{name}
```

After creating the worktree, call `session-rename_sync_branch`.

Branch types: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

## Source vs Deployed Copy

- Source: `~/Git/aidevops/.agents/` — git-tracked, branch matters
- Deployed: `~/.aidevops/agents/` — copied output, not a git repo

Run `pre-edit-check.sh` in the source repo before changing either location.
