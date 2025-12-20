---
description: Full release workflow with version bump, tag, and GitHub release
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

# Release Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Full release**: `.agent/scripts/version-manager.sh release [major|minor|patch] --skip-preflight`
- **CRITICAL**: Always use the script above - it updates all 5 version files atomically
- **NEVER** manually edit VERSION, bump versions yourself, or use separate commands

**Before releasing**: Check for uncommitted changes and commit them first:

```bash
git status --short  # Check for uncommitted changes
git add -A && git commit -m "feat: description of changes"  # Commit if needed
```

- **Auto-changelog**: Release script auto-generates CHANGELOG.md from conventional commits
- **Create tag**: `.agent/scripts/version-manager.sh tag`
- **GitHub release**: `.agent/scripts/version-manager.sh github-release`
- **Postflight**: `.agent/scripts/postflight-check.sh` (verify after release)
- **Validator**: `.agent/scripts/validate-version-consistency.sh`
- **GitHub Actions**: `.github/workflows/version-validation.yml`
- **Version bump only**: See `workflows/version-bump.md`
- **Changelog format**: See `workflows/changelog.md`
- **Postflight verification**: See `workflows/postflight.md` (verify after release)

<!-- AI-CONTEXT-END -->

This workflow covers the release process: tagging, pushing, and creating GitHub/GitLab releases. For version number management only, see `workflows/version-bump.md`. For changelog format and validation, see `workflows/changelog.md`. For PR-based merges before release, see `workflows/pr.md`.

## Pre-Release Checklist

Before running the release command:

- [ ] All working changes committed (no uncommitted files)
- [ ] Tests passing
- [ ] CHANGELOG.md has unreleased content (or use `--force`)

The release script will **refuse to release** if there are uncommitted changes.
This prevents accidentally releasing without your session's work.

## Release Workflow Overview

The release script handles everything automatically:

1. **Check for uncommitted changes** (fails if dirty, use `--allow-dirty` to bypass)
2. Bump version in all files (VERSION, README.md, setup.sh, sonar-project.properties, package.json)
3. **Auto-generate CHANGELOG.md** from conventional commits
4. Validate version consistency
5. Commit all changes
6. Create version tag
7. Push to remote
8. Create GitHub release
9. Post-release verification

## Quick Release (aidevops)

**MANDATORY**: Use this single command for ALL releases:

```bash
./.agent/scripts/version-manager.sh release [major|minor|patch] --skip-preflight
```

**Flags**:
- `--skip-preflight` - Skip linting checks (faster)
- `--force` - Bypass empty changelog check
- `--allow-dirty` - Release with uncommitted changes (not recommended)

This command:
1. Checks for uncommitted changes (fails if dirty)
2. Bumps version in all 5 files atomically (VERSION, README.md, setup.sh, sonar-project.properties, package.json)
3. **Auto-generates CHANGELOG.md** from conventional commits (feat:, fix:, docs:, etc.)
4. Validates consistency
5. Commits version bump + changelog
6. Creates git tag
7. Pushes to remote
8. Creates GitHub release

**DO NOT** run separate bump/tag/push commands - use this single command only.

## Auto-Changelog Generation

The release script automatically generates changelog entries from conventional commits:

| Commit Type | Changelog Section |
|-------------|-------------------|
| `feat:` | Added |
| `fix:` | Fixed |
| `docs:` | Changed (Documentation) |
| `refactor:` | Changed (Refactor) |
| `perf:` | Changed (Performance) |
| `security:` | Security |
| `BREAKING CHANGE:` | Removed (BREAKING) |
| `deprecate:` | Deprecated |

Commits with `chore:` prefix are excluded from the changelog.

**Best practice**: Use conventional commit messages for accurate changelog generation:

```bash
git commit -m "feat: add DataForSEO MCP integration"
git commit -m "fix: resolve Serper API authentication"
git commit -m "docs: update release workflow documentation"
```

## Pre-Release Checklist

Before starting a release:

- [ ] All planned features are merged
- [ ] All critical bugs are resolved
- [ ] CI/CD pipelines are passing
- [ ] Documentation is up to date
- [ ] Dependencies are updated and audited
- [ ] Security vulnerabilities addressed

## Detailed Release Steps

### 1. Create a Release Branch (Optional)

For larger projects, create a release branch:

```bash
git checkout main
git pull origin main
git checkout -b release/v{MAJOR}.{MINOR}.{PATCH}
```

### 2. Run Code Quality Checks

```bash
# For this framework
./.agent/scripts/linters-local.sh

# Generic checks
npm run lint && npm test
flake8 . && pytest
go vet ./... && go test ./...
```

### 3. Changelog (Auto-Generated)

The release script **automatically generates** CHANGELOG.md entries from conventional commits. No manual changelog editing required.

```bash
# Preview what will be generated (optional)
./.agent/scripts/version-manager.sh changelog-preview

# Validate existing changelog (optional)
./.agent/scripts/version-manager.sh changelog-check
```

The auto-generated changelog follows [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- Feature from feat: commits

### Changed
- Changes from docs:, refactor:, perf: commits

### Fixed
- Fixes from fix: commits
```

See `workflows/changelog.md` for manual changelog guidance if needed.

### 4. Commit Version Changes

```bash
git add -A
git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}"
```

### 5. Create Version Tags

```bash
# Using version-manager (preferred)
./.agent/scripts/version-manager.sh tag

# Or manually
git tag -a v{VERSION} -m "Release v{VERSION}"
```

### 6. Push to Remote

```bash
git push origin main
git push origin --tags

# For multiple remotes
git push github main --tags
git push gitlab main --tags
```

### 7. Create GitHub/GitLab Release

**Using version-manager (preferred):**

```bash
./.agent/scripts/version-manager.sh github-release
```

**Using GitHub CLI:**

```bash
gh release create v{VERSION} \
  --title "v{VERSION}" \
  --notes-file RELEASE_NOTES.md \
  ./dist/*
```

**Using GitLab CLI:**

```bash
glab release create v{VERSION} \
  --name "v{VERSION}" \
  --notes-file RELEASE_NOTES.md
```

## GitHub Integration

### Authentication Methods

**1. GitHub CLI (Preferred):**

```bash
brew install gh  # macOS
gh auth login
```

**2. GitHub API (Fallback):**

```bash
export GITHUB_TOKEN=your_personal_access_token
```

### GitHub Actions Automation

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: npm run build
      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: dist/*
          generate_release_notes: true
```

## Post-Release Tasks

### Time Summary

After release, update TODO.md and PLANS.md with actual time spent:

```markdown
# Update completed tasks with actual: field
# Before: - [x] Add user dashboard #feature ~4h started:2025-01-15T10:30Z completed:2025-01-16T14:00Z
# After:  - [x] Add user dashboard #feature ~4h actual:5h30m started:2025-01-15T10:30Z completed:2025-01-16T14:00Z
```

**Time summary report** (generated at release):

```markdown
## Release v1.2.0 Time Summary

| Task | Estimated | Actual | Variance |
|------|-----------|--------|----------|
| Add user dashboard | 4h | 5h30m | +1h30m |
| Fix login timeout | 2h | 1h45m | -15m |
| **Total** | **6h** | **7h15m** | **+1h15m** |

Estimation accuracy: 83%
```

The release script can optionally generate this summary from TODO.md TOON blocks.

### Postflight Verification

After release publication, run postflight checks to verify release health:

```bash
# Run full postflight verification
./.agent/scripts/postflight-check.sh

# Quick check (CI/CD + SonarCloud only)
./.agent/scripts/postflight-check.sh --quick

# Or check CI/CD manually
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status
```

See `workflows/postflight.md` for detailed verification procedures and rollback guidance.

### Immediate

1. Run postflight verification (see above)
2. Verify release artifacts and download links
3. Update documentation site
4. Notify stakeholders
5. Monitor for issues

### Follow-up

1. Update dependent projects
2. Close release milestone
3. Start next version planning
4. Update roadmap

## Rollback Procedures

### Identify the Issue

```bash
git log --oneline -10
git diff v{PREVIOUS} v{CURRENT}
```

### Create Hotfix

```bash
git checkout -b hotfix/v{NEW_PATCH}
# Fix the issue
git commit -m "fix: resolve critical issue"
```

### Or Revert

```bash
git revert <commit-hash>
git commit -m "revert: rollback v{CURRENT}"
```

## Troubleshooting

### Tag Already Exists

```bash
git tag -d v{VERSION}
git push origin --delete v{VERSION}
git tag -a v{VERSION} -m "Release v{VERSION}"
git push origin v{VERSION}
```

### GitHub CLI Not Authenticated

```bash
gh auth login
```

### GitHub Token Issues

```bash
# Check token permissions (needs 'repo' scope)
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user
```

### Version Mismatch

```bash
# Validate consistency
./.agent/scripts/version-manager.sh validate

# See version-bump.md for fixing
```

## Release Types

See `workflows/version-bump.md` for semantic versioning rules (major/minor/patch). Hotfixes follow patch versioning with an expedited release process.

## Release Communication Template

```markdown
# [Project Name] v{X.Y.Z} Released

## Highlights
- Feature 1: Description
- Feature 2: Description

## Breaking Changes
- Description of any breaking changes

## Upgrade Guide
1. Step to upgrade
2. Migration notes

## Full Changelog
See [CHANGELOG.md](link) for complete details.
```
