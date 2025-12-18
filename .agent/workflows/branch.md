---
description: Git branch creation and management workflow
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

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
| Version release | `release/` | `branch/release.md` |

**Branch naming**: `{type}/{short-description}` (e.g., `feature/user-dashboard`)

**Mandatory start**:

```bash
git checkout main && git pull origin main && git checkout -b {type}/{description}
```text

**Lifecycle**: Create → Develop → Preflight → Version → Push → PR → Review → Merge → Release → Postflight → Cleanup

<!-- AI-CONTEXT-END -->

## Purpose

This workflow ensures all build agents use consistent branching practices. Every code change should go through a branch, PR, and merge process.

**Important**: Before creating branches, read `workflows/git-workflow.md` for the complete git workflow including issue URL handling, fork detection, and new repo initialization.

## Checking for Existing Work

Before starting new work, check for WIP branches:

```bash
# List all branches with WIP or your current work
git branch -a | grep -E "(feature|bugfix|hotfix|refactor|chore|experiment)/"

# Check current branch
git branch --show-current
```text

If a relevant branch exists, continue on it rather than creating a new one.

## Creating a New Branch

**Always start from updated main:**

```bash
git checkout main
git pull origin main
git checkout -b {type}/{description}
```text

### Branch Type Selection

| If the task is... | Use branch type |
|-------------------|-----------------|
| Adding new capability | `feature/` |
| Fixing a bug (non-urgent) | `bugfix/` |
| Fixing production issue (urgent) | `hotfix/` |
| Restructuring code, same behavior | `refactor/` |
| Updating docs, deps, CI, config | `chore/` |
| Exploring, prototyping, POC | `experiment/` |
| Preparing a version release | `release/` |

### Naming Conventions

- Use lowercase with hyphens: `feature/user-authentication`
- Be descriptive but concise: `bugfix/login-timeout` not `bugfix/fix`
- Include issue number if applicable: `bugfix/123-login-timeout`
- Release branches use version: `release/1.2.0` (semver format)

## Branch Lifecycle

```text
main ─────────────────────────────────────────────────────────────► main
       \                                                          /
        └─► feature/xyz ─► preflight ─► PR ─► review ─► merge ─► release
```text

### 1. Create Branch

Start from updated `main`. Reference domain agents for implementation guidance.

```bash
git checkout main && git pull origin main
git checkout -b {type}/{description}
```text

**Agents**: Domain agents (`wordpress.md`, `seo.md`, etc.) for implementation patterns

### 2. Develop

Regular commits following conventional format (`feat:`, `fix:`, `refactor:`, etc.).

**Agents**: `branch/{type}.md` for branch-specific guidance

### 3. Preflight (Local Quality)

Run quality checks before pushing. Catches issues early.

```bash
.agent/scripts/linters-local.sh --fast
```text

**Agents**: `workflows/preflight.md`

### 4. Version (If Applicable)

Bump version for releases. Skip for WIP or intermediate commits.

```bash
.agent/scripts/version-manager.sh bump [major|minor|patch]
```text

**Agents**: `workflows/version-bump.md`, `workflows/changelog.md`

### 5. Push

Push to remote for backup and collaboration.

```bash
git push -u origin HEAD
```text

### 6. Pull Request

Create PR/MR. CI/CD runs automatically.

```bash
gh pr create --fill        # GitHub
glab mr create --fill      # GitLab
```text

**Agents**: `workflows/pr.md`

### 7. Review Feedback

Address reviewer comments. Re-request review when ready.

```bash
git add . && git commit -m "fix: address review feedback"
git push
```text

**Agents**: `workflows/code-audit-remote.md`

### 8. Merge

Final CI/CD verification, then merge via PR.

```bash
gh pr merge --squash --delete-branch
```text

### 9. Release (If Applicable)

Tag and publish for version releases.

```bash
.agent/scripts/version-manager.sh release [major|minor|patch]
```text

**Agents**: `workflows/release.md`

### 10. Postflight

Verify CI/CD and quality tools after release.

```bash
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status
```text

**Agents**: `workflows/postflight.md`

### 11. Cleanup

Delete branch after merge (usually automatic).

```bash
git branch -d {branch-name}           # Local
git push origin --delete {branch-name} # Remote (if not auto-deleted)
```text

## Commit Message Standards

Use conventional commit format:

```text
type: brief description

Detailed explanation if needed.
Fixes #123
```text

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
```text

## Safety: Protecting Uncommitted Work

**Before destructive operations** (reset, clean, rebase, checkout with changes):

```bash
# Protect ALL work including untracked files
git stash --include-untracked -m "safety: before [operation]"

# After operation, restore if needed
git stash pop
```text

**Why this matters**: `git restore` only recovers tracked files. Untracked new files are permanently lost without stash.

**Safe workflow**:
1. `git stash --include-untracked` before risky operations
2. Perform operation
3. `git stash pop` to restore work
4. If stash conflicts, `git stash show -p` to review

## Full Workflow Chain

```text
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Create    2. Develop    3. Preflight    4. Version    5. Push      │
│  branch.md    branch/*.md   preflight.md    version-bump  (git push)   │
│                                             changelog.md               │
├─────────────────────────────────────────────────────────────────────────┤
│  6. PR           7. Review      8. Merge       9. Release   10. Post   │
│  pull-request    code-review    (gh pr merge)  release.md   postflight │
├─────────────────────────────────────────────────────────────────────────┤
│  11. Cleanup - Delete branch after merge                               │
└─────────────────────────────────────────────────────────────────────────┘
```text

### Lifecycle Summary

| Stage | Action | Agent/Command | Required |
|-------|--------|---------------|----------|
| 1 | Create branch | `branch.md`, `branch/{type}.md` | Yes |
| 2 | Develop | Domain agents, conventional commits | Yes |
| 3 | Preflight | `preflight.md`, `linters-local.sh` | Yes |
| 4 | Version | `version-bump.md`, `changelog.md` | For releases |
| 5 | Push | `git push -u origin HEAD` | Yes |
| 6 | PR | `pull-request.md` | Yes |
| 7 | Review | `code-review.md` | Yes |
| 8 | Merge | `gh pr merge --squash` | Yes |
| 9 | Release | `release.md` | For releases |
| 10 | Postflight | `postflight.md` | For releases |
| 11 | Cleanup | Delete branch | Yes |

## Related Workflows

- **Pull requests**: `workflows/pr.md` (review before merge)
- **Preflight**: `workflows/preflight.md` (quality checks before release)
- **Version bumping**: `workflows/version-bump.md`
- **Changelog**: `workflows/changelog.md`
- **Creating releases**: `workflows/release.md`
- **Postflight**: `workflows/postflight.md` (verify after release)
- **Code review**: `workflows/code-audit-remote.md`
