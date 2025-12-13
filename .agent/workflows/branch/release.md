---
description: Release branch workflow for version preparation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Release Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Prepare a new version for release
- **Naming**: `release/{MAJOR}.{MINOR}.{PATCH}` (e.g., `release/1.2.0`)
- **Create from**: `main` (or latest stable)
- **Merge to**: `main` via PR, then tag

**Commands**:

```bash
# Create release branch
git checkout main && git pull origin main
git checkout -b release/1.2.0

# After preparation, merge to main
gh pr create --base main --title "Release v1.2.0"
gh pr merge --squash

# Tag the release
git checkout main && git pull
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin v1.2.0
```

<!-- AI-CONTEXT-END -->

## When to Create a Release Branch

| Scenario | Action |
|----------|--------|
| Features ready for release | Create `release/X.Y.0` |
| Bug fixes accumulated | Create `release/X.Y.Z` (patch) |
| Breaking changes ready | Create `release/X+1.0.0` |
| Hotfix needed | Use `hotfix/` branch instead |

## Release Branch Lifecycle

### 1. Create Release Branch

```bash
# Ensure main is up to date
git checkout main
git pull origin main

# Create release branch
git checkout -b release/{VERSION}
```

### 2. Select Changes to Include

If cherry-picking specific branches:

```bash
# List unmerged feature branches
git branch --no-merged main | grep -E "^  (feature|bugfix)/"

# Cherry-pick specific commits
git cherry-pick {commit-hash}

# Or merge entire branches
git merge feature/specific-feature --no-ff
```

### 3. Update Version Files

```bash
# Use version-manager for atomic updates
.agent/scripts/version-manager.sh bump {major|minor|patch}
```

This updates:

- VERSION
- package.json
- README.md badge
- setup.sh
- sonar-project.properties

### 4. Update Changelog

Update CHANGELOG.md:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added

- Feature A
- Feature B

### Fixed

- Bug fix C

### Changed

- Improvement D
```

### 5. Final Testing

```bash
# Run all quality checks
.agent/scripts/linters-local.sh

# Run tests
npm test  # or appropriate test command
```

### 6. Create PR to Main

```bash
git push -u origin release/{VERSION}
gh pr create --base main --title "Release v{VERSION}" --body "## Release v{VERSION}

### Changes

- Feature A
- Feature B
- Bug fix C

### Checklist

- [ ] Version files updated
- [ ] Changelog updated
- [ ] Tests passing
- [ ] Quality checks passing"
```

### 7. Merge and Tag

After PR approval:

```bash
# Merge PR
gh pr merge --squash --delete-branch

# Update local main
git checkout main
git pull origin main

# Create tag
git tag -a v{VERSION} -m "Release v{VERSION}"
git push origin v{VERSION}

# Create GitHub release
gh release create v{VERSION} --generate-notes
```

### 8. Post-Release

```bash
# Run postflight verification
.agent/scripts/postflight-check.sh

# Clean up local release branch (if not auto-deleted)
git branch -d release/{VERSION}
```

## Version Selection Guide

| Change Type | Version Bump | Example |
|-------------|--------------|---------|
| Bug fixes only | Patch | 1.2.3 → 1.2.4 |
| New features (backward compatible) | Minor | 1.2.3 → 1.3.0 |
| Breaking changes | Major | 1.2.3 → 2.0.0 |
| Initial development | 0.x.y | 0.1.0 → 0.2.0 |

## Difference from Hotfix

| Aspect | Release Branch | Hotfix Branch |
|--------|----------------|---------------|
| Urgency | Planned | Urgent |
| Source | `main` | Latest tag |
| Content | Multiple features/fixes | Single critical fix |
| Testing | Full test cycle | Minimal, focused |
| Naming | `release/X.Y.Z` | `hotfix/description` |

## Related Workflows

- `version-bump.md` - Version file management
- `release.md` - Full release process
- `changelog.md` - Changelog format
- `postflight.md` - Post-release verification
- `branch/hotfix.md` - Urgent production fixes
