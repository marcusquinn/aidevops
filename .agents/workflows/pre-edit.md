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
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "description" --file "path/to/file"
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
> 3. Stay on `main` (allowlisted path only)

**Exit 3 prompt:**
> On branch: `{branch}` (main repo, not worktree)
> 1. Create worktree for this task (recommended)
> 2. Continue on current branch
> 3. Switch to `main`, then create worktree

## Main-Branch File Allowlist (t1712)

When `--file <path>` is provided, the script enforces a **path-based** allowlist instead of task-description heuristics. Only these paths are writable on `main`/`master` without a linked worktree:

- `README.md`
- `TODO.md`
- `todo/**` (all files under the planning directory)

All other paths require a linked worktree. This is also enforced by `git_safety_guard.py` for Edit/Write tool calls in Claude Code.

## Loop Mode Keywords (fallback, no --file)

When no `--file` is provided, the script falls back to task-description heuristics:

- **Docs-only** (`readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`) → stay on `main`
- **Code** (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`) → create worktree; code keywords override docs keywords

## Worktree Default

Keep `~/Git/{repo}/` on `main`. Avoids blocked branch switches, parallel sessions inheriting the wrong branch, and `local changes would be overwritten` errors.

Stay on `main` only for: `README.md`, `TODO.md`, and `todo/**` (planning files). Planning-file commits use `planning-commit-helper.sh "plan: add new task"`.

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
