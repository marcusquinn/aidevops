---
mode: subagent
tools:
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Pre-Edit Git Check

Run before any file edits:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --file "path/to/file"
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

Pass `--file <path>` when the target file is known — this enables path-based enforcement (t1712). `--task` description heuristics are a fallback for callers that don't know the target path.

## Main-Branch Write Allowlist (t1712)

Only these paths are writable on `main`/`master` without a linked worktree:

| Path | Purpose |
|------|---------|
| `README.md` | Top-level readme |
| `TODO.md` | Task backlog |
| `todo/**` | Plans, briefs, task files |

All other paths require a linked worktree. The `git_safety_guard.py` hook enforces this for `Edit` and `Write` tool calls automatically.

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Safe to edit | Proceed |
| `1` | On `main`/`master` | STOP — present prompt below, WAIT for reply |
| `2` | Loop mode needs worktree | Auto-create worktree |
| `3` | Feature branch in main repo | Present exit-3 options below |

**Exit 1 prompt** (non-allowlisted path on `main`, interactive mode only):
> On `main`. Suggested branch: `{type}/{suggested-name}`
> 1. Create worktree (recommended)
> 2. Use different branch name

Note: allowlisted paths (`README.md`, `TODO.md`, `todo/**`) short-circuit to exit `0` before this prompt is shown.

**Exit 3 prompt:**
> On branch: `{branch}` (main repo, not worktree)
> 1. Create worktree for this task (recommended)
> 2. Continue on current branch
> 3. Switch to `main`, then create worktree

## Loop Mode

Pass `--file <path>` for path-based enforcement (preferred):

- **Allowlisted path** (`README.md`, `TODO.md`, `todo/**`) → stay on `main`
- **Any other path** → create worktree

Fallback `--task` description keywords (when `--file` not provided):

- **Docs-only** (`readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`) → stay on `main`
- **Code** (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`) → create worktree; code keywords override docs keywords

## Worktree Default

Keep `~/Git/{repo}/` on `main`. Avoids blocked branch switches, parallel sessions inheriting the wrong branch, and `local changes would be overwritten` errors.

Stay on `main` only for allowlisted paths: `README.md`, `TODO.md`, `todo/**`. Planning-file commits use `planning-commit-helper.sh "plan: add new task"`.

Continue on current branch only when: task matches branch purpose, finishes this session, no parallel sessions expected.

**Create worktree:**

```bash
wt switch -c {type}/{name}
~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{name}
```

After creating, call `session-rename_sync_branch`. Branch types: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

## Source vs Deployed Copy

- Source: `~/Git/aidevops/.agents/` — git-tracked, branch matters
- Deployed: `~/.aidevops/agents/` — copied output, not a git repo

Run `pre-edit-check.sh` in the source repo before changing either location.
