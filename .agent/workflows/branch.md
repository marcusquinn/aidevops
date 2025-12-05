# Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Before building**: Check for existing WIP branch
- **Continue WIP**: `git checkout <branch>` and resume
- **New work**: Create branch using type below, always from updated `main`

| Task Type | Branch Prefix | Subagent |
|-----------|---------------|----------|
| New functionality | `feature/` | `branch/feature.md` |
| Bug fix | `bugfix/` | `branch/bugfix.md` |
| Urgent production fix | `hotfix/` | `branch/hotfix.md` |
| Code restructure | `refactor/` | `branch/refactor.md` |
| Docs, deps, config | `chore/` | `branch/chore.md` |
| Spike, POC | `experiment/` | `branch/experiment.md` |

**Branch naming**: `{type}/{short-description}` (e.g., `feature/user-dashboard`)

**Mandatory start**:
```bash
git checkout main && git pull origin main && git checkout -b {type}/{description}
```

<!-- AI-CONTEXT-END -->

## Purpose

This workflow ensures all build agents use consistent branching practices. Every code change should go through a branch, PR, and merge process.

## Checking for Existing Work

Before starting new work, check for WIP branches:

```bash
# List all branches with WIP or your current work
git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment)/"

# Check current branch
git branch --show-current
```

If a relevant branch exists, continue on it rather than creating a new one.

## Creating a New Branch

**Always start from updated main:**

```bash
git checkout main
git pull origin main
git checkout -b {type}/{description}
```

### Branch Type Selection

| If the task is... | Use branch type |
|-------------------|-----------------|
| Adding new capability | `feature/` |
| Fixing a bug (non-urgent) | `bugfix/` |
| Fixing production issue (urgent) | `hotfix/` |
| Restructuring code, same behavior | `refactor/` |
| Updating docs, deps, CI, config | `chore/` |
| Exploring, prototyping, POC | `experiment/` |

### Naming Conventions

- Use lowercase with hyphens: `feature/user-authentication`
- Be descriptive but concise: `bugfix/login-timeout` not `bugfix/fix`
- Include issue number if applicable: `bugfix/123-login-timeout`

## Branch Lifecycle

```
main ─────────────────────────────────────────► main
       \                                    /
        └─► feature/xyz ─► PR ─► review ─► merge
```

1. **Create** branch from `main`
2. **Develop** with regular commits
3. **Push** to remote for backup/collaboration
4. **PR** when ready for review
5. **Review** and address feedback
6. **Merge** via PR (squash or merge commit)
7. **Delete** branch after merge

## Commit Message Standards

Use conventional commit format:

```
type: brief description

Detailed explanation if needed.
Fixes #123
```

| Type | Usage |
|------|-------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `refactor:` | Code restructure |
| `docs:` | Documentation |
| `chore:` | Maintenance |
| `test:` | Tests |

## Keeping Branch Updated

If `main` has been updated while you're working:

```bash
git checkout main
git pull origin main
git checkout your-branch
git merge main
# Resolve conflicts if any
```

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Creating releases**: `workflows/release.md`
- **Code review**: `workflows/code-review.md`
