---
mode: subagent
tools:
  bash: true
---
# Pre-Edit Git Check

## Usage

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
# Loop mode (headless/full-loop):
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | OK to proceed | Continue with edits |
| `1` | On protected branch (main/master) | STOP — present branch options (interactive) |
| `2` | Loop mode: worktree needed | Auto-create worktree |
| `3` | Feature branch in main repo | Present options to user |

## Interactive Prompts

**Exit 1 — on main:** Present and WAIT for user response (do NOT proceed without reply):

> On `main`. Suggested branch: `{type}/{suggested-name}`
>
> 1. Create worktree (recommended)
> 2. Use different branch name
> 3. Stay on `main` (docs-only)

**Exit 3 — feature branch in main repo:**

> On branch: `{branch}` (main repo, not worktree)
>
> 1. Create worktree for this task (recommended)
> 2. Continue on current branch
> 3. Switch to main, then create worktree

## Loop Mode Auto-Decision

- **Docs-only** (`readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`) → stay on main
- **Code** (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`) → create worktree (overrides docs keywords)

## Worktree Rationale

Main repo (`~/Git/{repo}/`) stays on `main` always. Prevents: uncommitted changes blocking switches, parallel sessions inheriting wrong branch, "local changes would be overwritten" errors.

**Stay on main acceptable for:** docs-only (README, CHANGELOG, docs/), typos, version bumps, planning files (TODO.md, todo/).

**Planning files** edit directly on main: `planning-commit-helper.sh "plan: add new task"`

## Feature Branch Scenarios

| Scenario | Script Output | Action |
|----------|---------------|--------|
| In worktree | `OK - On branch: X (in worktree)` | Proceed |
| In main repo | `WARNING - MAIN REPO ON FEATURE BRANCH` | Present exit 3 options |

**Continue on current branch** acceptable IF: task relates to current branch purpose, will complete before session ends, no parallel sessions expected.

## aidevops Framework Note

Two locations: **Source** `~/Git/aidevops/.agents/` (git repo, check branch here) and **Deployed** `~/.aidevops/agents/` (copy, not git). Run pre-edit-check.sh in source repo BEFORE changes to either.

## Worktree Creation

```bash
# Preferred
wt switch -c {type}/{name}
# Fallback
~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{name}
```

After creating, call `session-rename_sync_branch` tool.

**Branch types:** `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`
