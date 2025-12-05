# Pull Request Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Create, review, and merge PRs/MRs across platforms
- **Prerequisite**: Branch created per `workflows/branch.md`
- **Post-merge**: Tag releases per `workflows/release.md`

| Platform | CLI | Create | Merge |
|----------|-----|--------|-------|
| GitHub | `gh` | `gh pr create --fill` | `gh pr merge --squash` |
| GitLab | `glab` | `glab mr create --fill` | `glab mr merge --squash` |
| Gitea | `tea` | `tea pulls create` | `tea pulls merge` |

**Workflow Position**:

```
branch.md → pull-request.md → release.md
(create)    (review/merge)    (tag/publish)
```

**When to Create PR**:
- Code review required before merge
- CI/CD checks must pass
- Someone else will review/merge
- Audit trail needed for changes

**Quick PR** (auto-fill from commits):

```bash
git push -u origin HEAD
gh pr create --fill        # GitHub
glab mr create --fill      # GitLab
```

<!-- AI-CONTEXT-END -->

## Purpose

This workflow covers creating pull requests (GitHub/Gitea) or merge requests (GitLab) when:

1. **Code review is required** - Team policy or quality gates
2. **CI/CD must pass** - Automated tests, linting, security scans
3. **Separation of duties** - Author shouldn't merge their own code
4. **Audit trail** - Documented approval history

For direct pushes to main (solo work, trusted contributors), see `workflows/branch.md` merge section.

## Workflow Integration

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ branch.md   │────►│ pull-request.md  │────►│ release.md  │
│             │     │                  │     │             │
│ - Create    │     │ - Push branch    │     │ - Tag       │
│ - Develop   │     │ - Create PR/MR   │     │ - Changelog │
│ - Commit    │     │ - Review         │     │ - Publish   │
│             │     │ - CI/CD checks   │     │             │
│             │     │ - Merge          │     │             │
└─────────────┘     └──────────────────┘     └─────────────┘
```

## Pre-PR Checklist

Before creating a PR:

- [ ] Branch is up to date with main (`git merge main`)
- [ ] All commits follow conventional format (`feat:`, `fix:`, etc.)
- [ ] Tests pass locally
- [ ] Linting passes (ShellCheck, ESLint, etc.)
- [ ] Documentation updated if needed
- [ ] No secrets or credentials in code

```bash
# Quick pre-PR validation
git checkout main && git pull
git checkout - && git merge main
# Run project-specific tests/linting
```

## Creating Pull Requests

### GitHub (`gh`)

```bash
# Push branch first
git push -u origin HEAD

# Create PR with auto-filled title/body from commits
gh pr create --fill

# Create PR with custom details
gh pr create \
  --title "feat: Add user authentication" \
  --body "## Summary
- Implements OAuth2 flow
- Adds session management

Closes #123"

# Create draft PR (not ready for review)
gh pr create --fill --draft

# Create PR targeting specific branch
gh pr create --fill --base develop

# Create PR and request reviewers
gh pr create --fill --reviewer @username,@team
```

### GitLab (`glab`)

```bash
# Push branch first
git push -u origin HEAD

# Create MR with auto-filled details
glab mr create --fill

# Create MR with custom details
glab mr create \
  --title "feat: Add user authentication" \
  --description "## Summary
- Implements OAuth2 flow
- Adds session management

Closes #123"

# Create draft MR
glab mr create --fill --draft

# Create MR targeting specific branch
glab mr create --fill --target-branch develop

# Create MR and assign reviewers
glab mr create --fill --reviewer @username
```

### Gitea (`tea`)

```bash
# Push branch first
git push -u origin HEAD

# Create PR
tea pulls create \
  --title "feat: Add user authentication" \
  --description "Summary of changes"

# Create PR targeting specific branch
tea pulls create --base develop

# List PRs
tea pulls list
```

## PR Description Template

Use this template for comprehensive PR descriptions:

```markdown
## Summary

Brief description of what this PR does and why.

## Changes

- Change 1
- Change 2
- Change 3

## Testing

- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing completed

## Screenshots (if UI changes)

[Add screenshots here]

## Related Issues

Closes #123
Related to #456

## Checklist

- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No breaking changes (or documented)
```

## Review Requirements

### Configuring Branch Protection

**GitHub** (via CLI):

```bash
# Require PR reviews before merge
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  -f required_pull_request_reviews='{"required_approving_review_count":1}'

# Require status checks
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  -f required_status_checks='{"strict":true,"contexts":["ci/test"]}'
```

**GitLab** (via settings):
- Settings > Repository > Protected Branches
- Set "Allowed to merge" to specific roles
- Enable "Require approval from code owners"

### Review Checklist

For reviewers, see `workflows/code-review.md`. Key points:

| Category | Check |
|----------|-------|
| **Functionality** | Does it work? Edge cases handled? |
| **Security** | Input validation? No secrets exposed? |
| **Performance** | No N+1 queries? Efficient algorithms? |
| **Tests** | Adequate coverage? Tests pass? |
| **Docs** | Updated if needed? |

## CI/CD Integration

### GitHub Actions

PRs automatically trigger workflows defined in `.github/workflows/`:

```yaml
# .github/workflows/pr-checks.yml
name: PR Checks

on:
  pull_request:
    branches: [main, develop]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: npm test
      
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run linting
        run: npm run lint
```

### Checking CI Status

```bash
# GitHub - view PR checks
gh pr checks

# GitHub - wait for checks to pass
gh pr checks --watch

# GitLab - view pipeline status
glab ci status
```

## Merging Pull Requests

### Merge Strategies

| Strategy | Command | When to Use |
|----------|---------|-------------|
| **Squash** | `--squash` | Multiple commits → single clean commit |
| **Merge** | `--merge` | Preserve full commit history |
| **Rebase** | `--rebase` | Linear history, no merge commits |

**Recommendation**: Use squash for feature branches to keep main history clean.

### GitHub

```bash
# Squash merge (recommended)
gh pr merge 123 --squash

# Merge commit
gh pr merge 123 --merge

# Rebase merge
gh pr merge 123 --rebase

# Auto-merge when checks pass
gh pr merge 123 --squash --auto

# Delete branch after merge
gh pr merge 123 --squash --delete-branch
```

### GitLab

```bash
# Squash merge
glab mr merge 123 --squash

# Regular merge
glab mr merge 123

# Delete source branch after merge
glab mr merge 123 --remove-source-branch

# Merge when pipeline succeeds
glab mr merge 123 --when-pipeline-succeeds
```

### Gitea

```bash
# Merge PR
tea pulls merge 123

# With specific strategy
tea pulls merge 123 --style squash
```

## Post-Merge Actions

After merging:

1. **Delete branch** (if not auto-deleted):

   ```bash
   git branch -d feature/xyz           # Local
   git push origin --delete feature/xyz # Remote
   ```

2. **Update local main**:

   ```bash
   git checkout main
   git pull origin main
   ```

3. **Create release** (if applicable):
   See `workflows/release.md`

4. **Close related issues** (usually automatic via "Closes #123")

## Handling PR Feedback

When reviewers request changes:

```bash
# Make requested changes
git add .
git commit -m "fix: Address review feedback"
git push

# Or amend last commit (if minor fix)
git add .
git commit --amend --no-edit
git push --force-with-lease
```

**Re-request review** after addressing feedback:

```bash
# GitHub
gh pr ready  # Mark as ready (if was draft)

# Request re-review
gh api repos/{owner}/{repo}/pulls/123/requested_reviewers \
  -X POST -f reviewers='["username"]'
```

## Troubleshooting

### PR Won't Merge

| Issue | Solution |
|-------|----------|
| Merge conflicts | `git merge main`, resolve conflicts, push |
| Checks failing | Fix issues, push new commits |
| Reviews pending | Request review or wait for approval |
| Branch protection | Ensure all requirements met |

### Resolving Merge Conflicts

```bash
# Update your branch with main
git checkout main
git pull origin main
git checkout your-branch
git merge main

# Resolve conflicts in editor
# Then:
git add .
git commit -m "fix: Resolve merge conflicts"
git push
```

### Stale PR

If PR has been open too long:

```bash
# Rebase on latest main
git checkout main
git pull
git checkout your-branch
git rebase main
git push --force-with-lease
```

## Platform-Specific Notes

### GitHub

- PRs can be converted to/from drafts
- Auto-merge available with branch protection
- Supports PR templates in `.github/PULL_REQUEST_TEMPLATE.md`

### GitLab

- Called "Merge Requests" (MRs)
- Supports merge trains for sequential merging
- MR templates in `.gitlab/merge_request_templates/`

### Gitea

- Similar to GitHub PRs
- Lighter weight, good for self-hosted
- PR templates in `.gitea/PULL_REQUEST_TEMPLATE.md`

## Related Workflows

- **Branch creation**: `workflows/branch.md`
- **Code review**: `workflows/code-review.md`
- **Releases**: `workflows/release.md`
- **Git CLI tools**: `tools/git.md`
