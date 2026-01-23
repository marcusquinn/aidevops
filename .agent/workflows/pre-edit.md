---
mode: subagent
tools:
  - bash
---
# Pre-Edit Git Check - Detailed Workflow

## Script Usage

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
```

## Exit Codes

| Exit Code | Meaning | Required Action |
|-----------|---------|-----------------|
| `0` | OK to proceed | Continue with edits |
| `1` | On protected branch (main/master) | STOP - present branch creation options |
| `2` | Loop mode: worktree needed | Auto-create worktree for code task |
| `3` | On feature branch in main repo | Present options to user |

## Interactive Mode (Exit 1)

If on main, present this prompt and WAIT for user response:

> On `main`. Suggested branch: `{type}/{suggested-name}`
>
> 1. Create worktree (recommended - keeps main repo on main)
> 2. Use different branch name
> 3. Stay on `main` (docs-only, not recommended for code)

**Do NOT proceed until user replies with 1, 2, or 3**

## Feature Branch in Main Repo (Exit 3)

> Currently on branch: `{branch}` (in main repo, not worktree)
>
> 1. Create worktree for this task (recommended)
> 2. Continue on current branch (not recommended for code)
> 3. Switch main repo back to main, then create worktree
>
> Which would you prefer? [1/2/3]

## Loop Mode

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

Auto-decision rules:
- **Docs-only tasks** (README, CHANGELOG, docs/, typos) → Option 3 (stay on main)
- **Code tasks** (feature, fix, implement, refactor, enhance) → Option 1 (create worktree)

Detection keywords:
- Docs-only: `readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`
- Code (overrides docs): `feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`

## Why Worktrees Are Default

The main repo directory (`~/Git/{repo}/`) should ALWAYS stay on `main`. This prevents:
- Uncommitted changes blocking branch switches
- Parallel sessions inheriting wrong branch state
- "Your local changes would be overwritten" errors

## When Option 3 Is Acceptable

- Documentation-only changes (README, CHANGELOG, docs/)
- Typo fixes
- Version bumps via release script
- Planning files (TODO.md, todo/)

## Planning Files Exception

TODO.md and todo/ can be edited directly on main:

```bash
~/.aidevops/agents/scripts/planning-commit-helper.sh "plan: add new task"
```

## Feature Branch Scenarios

| Scenario | Script Output | Action |
|----------|---------------|--------|
| Feature branch in worktree | `OK - On branch: X (in worktree)` | Proceed normally |
| Feature branch in main repo | `WARNING - MAIN REPO ON FEATURE BRANCH` | Present options |
| Personal dev branch | Same as feature branch | Treat as feature branch |

## Small Tasks Exception

Option 2 (continue on current branch) is acceptable IF:
- The task is directly related to the current branch's purpose
- You'll complete and commit before ending the session
- No parallel sessions are expected

## Working in aidevops Framework

When modifying aidevops agents, you work in TWO locations:
- **Source**: `~/Git/aidevops/.agent/` - THIS is the git repo, check branch HERE
- **Deployed**: `~/.aidevops/agents/` - copy of source, not a git repo

Run pre-edit-check.sh in `~/Git/aidevops/` BEFORE any changes to either location.

## Worktree Creation

```bash
# Preferred: Worktrunk
wt switch -c {type}/{name}

# Fallback: worktree-helper.sh
~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{name}
```

After creating branch, call `session-rename_sync_branch` tool.

## Branch Types

`feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`
