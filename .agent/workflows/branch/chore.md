---
description: Chore branch for maintenance and non-code changes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  list: true
  webfetch: false
---

# Chore Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `chore/`
- **Example**: `chore/update-dependencies`, `chore/fix-ci-config`
- **Version bump**: Usually none
- **Scope**: Non-code changes, maintenance tasks

**Create**:

```bash
git checkout main && git pull origin main
git checkout -b chore/{description}
```

**Commit pattern**: `chore: description` or `docs:`, `ci:`, `build:`

<!-- AI-CONTEXT-END -->

## When to Use

Use `chore/` branches for:
- Dependency updates
- CI/CD configuration changes
- Documentation updates
- Build system changes
- Tooling configuration
- Code formatting/linting fixes
- License updates
- Gitignore changes

**Not for**: Code changes that affect behavior (use `feature/`, `bugfix/`, or `refactor/`).

## Branch Naming

```bash
# Dependency updates
chore/update-dependencies
chore/bump-node-version

# CI/CD
chore/fix-github-actions
chore/add-codecov

# Documentation
chore/update-readme
chore/add-contributing-guide

# Tooling
chore/configure-eslint
chore/add-prettier
```

## Workflow

1. Create branch from updated `main`
2. Make maintenance changes
3. Verify nothing is broken (run tests, build)
4. Commit with appropriate prefix
5. Push and create PR
6. Usually quick review/merge

## Commit Messages

Use specific prefixes when applicable:

```bash
# General maintenance
chore: update dependencies to latest versions

# Documentation
docs: add API usage examples to README

# CI/CD
ci: add caching to GitHub Actions workflow

# Build system
build: upgrade webpack to v5
```

## Version Impact

Chores typically have **no version bump**:
- No user-facing changes
- No behavior changes
- Internal maintenance only

Exception: Major dependency updates that users need to know about might warrant a patch bump.

## Common Chore Tasks

### Dependency Updates

```bash
# Check for updates
npm outdated
pip list --outdated

# Update and test
npm update
pip install --upgrade -r requirements.txt

# Commit
git commit -m "chore: update dependencies

- Updated package-a to 2.0.0
- Updated package-b to 1.5.0
- All tests pass"
```

### CI/CD Changes

```bash
git commit -m "ci: optimize GitHub Actions workflow

- Add dependency caching
- Run tests in parallel
- Reduce build time by 40%"
```

### Documentation

```bash
git commit -m "docs: improve installation instructions

- Add troubleshooting section
- Update screenshots
- Fix broken links"
```

## Related

- **Version bumping**: `workflows/version-bump.md` (usually not needed)
- **Code review**: `workflows/code-review.md`
