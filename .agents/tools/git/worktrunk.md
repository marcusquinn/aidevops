---
description: Worktrunk (wt) - Git worktree management for parallel AI agent workflows
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

# Worktrunk Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `wt` — Git worktree management for parallel AI workflows
- **Install**: `brew install max-sixty/worktrunk/wt && wt config shell install`
- **Cargo**: `cargo install worktrunk && wt config shell install`
- **Windows**: `winget install max-sixty.worktrunk` → use `git-wt` (avoids Windows Terminal alias conflict)
- **Docs**: https://worktrunk.dev
- **Fallback**: `~/.aidevops/agents/scripts/worktree-helper.sh` (no dependencies)

**Shell integration is required** for `wt switch` to change directories. Without it, commands only print the path.

**Core Commands**:

```bash
wt switch feat              # Switch to existing worktree (or create if branch exists)
wt switch -c feat           # Create new branch + worktree
wt switch -c -x claude feat # Create + start Claude Code
wt switch -c -x "npm install" feat  # Create + run command
wt list                     # List worktrees with CI status + PR links
wt remove                   # Remove current worktree + branch (prompts confirmation)
wt remove -f feat           # Force remove (skip confirmation)
wt merge                    # Interactive merge (squash/rebase/merge) + cleanup
wt merge --squash           # Squash merge directly
wt select                   # fzf-like worktree selector
wt commit                   # Commit with LLM-generated message (requires llm pip package)
```

<!-- AI-CONTEXT-END -->

## Why Worktrunk over raw git worktree?

| Task | Worktrunk | Plain git |
|------|-----------|-----------|
| Switch worktrees | `wt switch feat` | `cd ../repo.feat` |
| Create + start Claude | `wt switch -c -x claude feat` | `git worktree add -b feat ../repo.feat && cd ../repo.feat && claude` |
| Clean up | `wt remove` | `cd ../repo && git worktree remove ../repo.feat && git branch -d feat` |
| List with status | `wt list` | `git worktree list` (paths only) |
| Shell integration | Built-in (cd support) | Manual |
| Hooks | Yes (post-create, pre-merge, etc.) | No |
| CI status + PR links | Yes (in `wt list`) | No |
| Merge workflow | `wt merge` (squash/rebase) | Manual |
| LLM commits | Yes (via `llm`) | No |
| Dependencies | Rust binary | Bash only |

**Recommendation**: Use Worktrunk when available. Use `worktree-helper.sh` as fallback or in minimal environments.

## Hooks

Create `.worktrunk/hooks/` in your repo. Available hooks: `post-create`, `pre-merge`, `post-merge`, `pre-remove`.

```bash
# .worktrunk/hooks/post-create
#!/bin/bash
npm install
```

## Configuration

```bash
wt config show
wt config set path_template "../{repo}.{branch}"  # default
wt config set merge_strategy squash
wt config set llm_commits true  # AI-generated commit messages via llm
```

## Integration with aidevops

### Pre-Edit Check

`pre-edit-check.sh` works with both tools: detects protected branches, suggests worktree creation, auto-creates in loop mode.

### Localdev Integration (t1224.8)

When creating a worktree for a project registered with `localdev add`, `worktree-helper.sh` automatically:

1. Detects the project name from the repo path
2. Runs `localdev branch <project> <branch>` to create a subdomain route
3. Outputs the branch-specific URL (e.g., `http://feature-xyz.myapp.local` — `https://` if mkcert/local CA configured)

Route removal is automatic with `worktree-helper.sh`. For Worktrunk, add hooks:

```bash
# .worktrunk/hooks/post-create
#!/bin/bash
branch="$(git branch --show-current)"
project="$(basename "$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)")"
LOCALDEV_HELPER="${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/scripts/localdev-helper.sh"
"$LOCALDEV_HELPER" branch "$project" "$branch" 2>/dev/null || true
```

```bash
# .worktrunk/hooks/pre-remove
#!/bin/bash
branch="$(git branch --show-current)"
project="$(basename "$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)")"
LOCALDEV_HELPER="${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/scripts/localdev-helper.sh"
"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>/dev/null || true
```

### Session Naming

After creating a worktree, sync the session name via the `session-rename_sync_branch` MCP tool.

## Troubleshooting

**`wt: command not found`** — shell integration not installed:

```bash
wt config shell install && source ~/.zshrc  # or ~/.bashrc
```

**`Branch already checked out`** — each branch can only be in one worktree:

```bash
wt list                    # Find where branch is checked out
wt remove feature/auth     # Remove if not needed
```

**Windows: `wt` opens Windows Terminal** — use `git-wt` instead, or disable the Windows Terminal alias in Settings.

## Related

- `workflows/worktree.md` - Full worktree workflow documentation
- `workflows/git-workflow.md` - Branch naming and conventions
- `scripts/worktree-helper.sh` - Fallback bash implementation
- https://worktrunk.dev - Official documentation
