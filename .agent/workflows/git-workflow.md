# Git Workflow Guide for AI Assistants

This document provides comprehensive git workflow guidance for AI assistants working on any codebase.

## Core Git Workflow Principles

### 1. Always Start from Latest Main Branch

Before creating any new branch, always ensure you're working with the latest code:

```bash
git checkout main
git pull origin main
```

**This is mandatory.** Working from an outdated main branch leads to integration problems and merge conflicts.

### 2. One Issue Per Branch

Create a separate branch for each issue or feature:

| Branch Type | Naming Pattern | Example |
|-------------|----------------|---------|
| Bug fixes | `fix/issue-description` | `fix/123-login-error` |
| Features | `feature/descriptive-name` | `feature/user-dashboard` |
| Improvements | `patch/descriptive-name` | `patch/improve-caching` |
| Refactoring | `refactor/descriptive-name` | `refactor/extract-helpers` |
| Hotfixes | `hotfix/v{VERSION}` | `hotfix/v2.2.1` |

**Important:** Use descriptive names without version numbers for development branches. Only create version branches when changes are ready for release.

### 3. Pull Request for Each Issue

Create a separate pull request for each issue:

- Each change can be reviewed independently
- Issues can be merged as soon as they're ready
- Changes can be reverted individually if needed
- CI/CD checks run on focused changes

## Detailed Workflow

### Starting a New Task

```bash
# 1. Update main branch from origin (MANDATORY)
git checkout main
git pull origin main

# 2. Create a new branch
git checkout -b [branch-type]/[description]

# Examples:
git checkout -b fix/123-plugin-activation-error
git checkout -b feature/update-source-selector
git checkout -b patch/improve-error-messages
```

### Making Changes

```bash
# Make focused changes related only to the specific issue
# Commit regularly with clear, descriptive messages

git add .
git commit -m "Fix: Brief description of the change

Detailed explanation if needed.
Fixes #123"
```

### Testing Approach

**Local Testing (Default):**

```bash
# Test without updating version numbers
# Run tests, linters, quality checks
npm test
composer test
bash ~/git/aidevops/.agent/scripts/quality-check.sh
```

**Remote Testing (When Requested):**

```bash
git add .
git commit -m "WIP: Description for remote testing"
git push origin [branch-name]
```

### Push Branch to Remote

```bash
git push origin [branch-name]

# Or push to multiple remotes
git push github [branch-name]
git push gitlab [branch-name]
```

## Creating a Pull Request

### 1. Ensure Tests Pass Locally

```bash
# Run all available tests
npm test
composer test
# Run quality checks
bash ~/git/aidevops/.agent/scripts/quality-check.sh
```

### 2. Create Pull Request

Include in PR description:
- Clear description of changes
- Reference related issues (`Fixes #123`)
- Testing performed
- Screenshots if UI changes

### 3. Address Review Feedback

```bash
# Make requested changes
git add .
git commit -m "Address review: description of changes"
git push origin [branch-name]
```

## Handling Concurrent Development

### Keep Branches Independent

Always create new branches from the latest main:

```bash
# DON'T: Create from another feature branch
git checkout feature/other-feature
git checkout -b feature/new-feature  # BAD

# DO: Create from updated main
git checkout main
git pull origin main
git checkout -b feature/new-feature  # GOOD
```

### Handle Conflicts Proactively

```bash
# If main has been updated while you're working:
git checkout main
git pull origin main
git checkout your-branch
git merge main
# Resolve conflicts, then continue
```

### Coordinate on Dependent Changes

- Note dependencies in PR description: "Depends on #PR-number"
- Consider using feature flags for independent merging
- Document dependencies between PRs

## Commit Message Standards

### Format

```text
Type: Brief description (under 50 chars)

Detailed explanation if needed.
- Bullet points for multiple changes
- Reference issues: Fixes #123

Co-authored-by: Name <email>
```

### Types

| Type | Usage |
|------|-------|
| `Fix:` | Bug fixes |
| `Add:` | New features |
| `Update:` | Enhancements to existing features |
| `Remove:` | Removing code/features |
| `Refactor:` | Code restructuring |
| `Docs:` | Documentation changes |
| `Test:` | Test additions/changes |
| `Chore:` | Maintenance tasks |

### Best Practices

- Use present tense ("Add feature" not "Added feature")
- Keep the first line under 50 characters
- Reference issues when relevant
- Add detailed description for complex changes

## Branch Management

### Cleanup

```bash
# Delete merged local branches
git branch -d branch-name

# Delete remote branch
git push origin --delete branch-name

# Prune stale remote tracking branches
git fetch --prune
```

### View Branch Status

```bash
# List all branches with last commit
git branch -av

# Show branches merged to main
git branch --merged main

# Show unmerged branches
git branch --no-merged main
```

## Contributing to External Repositories

### Workflow for External Contributions

```bash
# 1. Clone the repository
cd ~/git
git clone https://github.com/owner/repo.git
cd repo

# 2. Create feature branch
git checkout -b feature/descriptive-branch-name

# 3. Make changes and commit
git add -A
git commit -m "Descriptive commit message

Detailed explanation.
Fixes #issue-number"

# 4. Fork and push
gh repo fork owner/repo --clone=false --remote=true
git remote add fork https://github.com/your-username/repo.git
git push fork feature/descriptive-branch-name

# 5. Create pull request
gh pr create \
  --repo owner/repo \
  --head your-username:feature/descriptive-branch-name \
  --title "Clear, descriptive title" \
  --body "Description of changes..."
```

### Testing Status in PRs

Always indicate testing status in PR description:

- **Not tested**: "This PR addresses [issue] but has not been tested. Ready for community/maintainer testing."
- **Locally tested**: "Tested in local environment with [results]."
- **Remotely tested**: "Tested with remote build with [results]."

## Quick Reference

```bash
# Start new work
git checkout main && git pull origin main && git checkout -b fix/issue-name

# Commit changes
git add . && git commit -m "Fix: Description"

# Push for review
git push origin fix/issue-name

# Update from main
git fetch origin && git merge origin/main

# Clean up after merge
git checkout main && git pull && git branch -d fix/issue-name
```
