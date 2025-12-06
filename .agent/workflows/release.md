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

- **Full release**: `.agent/scripts/version-manager.sh release [major|minor|patch]`
- **NEVER edit VERSION directly** - The script updates all 5 version files atomically
- **Create tag**: `.agent/scripts/version-manager.sh tag`
- **GitHub release**: `.agent/scripts/version-manager.sh github-release`
- **Postflight**: `.agent/scripts/postflight-check.sh` (verify after release)
- **Validator**: `.agent/scripts/validate-version-consistency.sh`
- **GitHub Actions**: `.github/workflows/version-validation.yml`
- **Version bump only**: See `workflows/version-bump.md`
- **Changelog**: See `workflows/changelog.md` (enforced before release)
- **Postflight verification**: See `workflows/postflight.md` (verify after release)
- **Fail-Safe**: Won't create releases if version inconsistencies or empty changelog

<!-- AI-CONTEXT-END -->

This workflow covers the release process: tagging, pushing, and creating GitHub/GitLab releases. For version number management only, see `workflows/version-bump.md`. For changelog format and validation, see `workflows/changelog.md`. For PR-based merges before release, see `workflows/pr.md`.

## Release Workflow Overview

1. Bump version (see `workflows/version-bump.md`)
2. Run code quality checks
3. Update changelog
4. Commit version changes
5. Create version tags
6. Push to remote
7. Create GitHub/GitLab release
8. Post-release tasks

## Quick Release (aidevops)

For this framework, use the integrated release command:

```bash
# Bump version, update files, validate, create tag, and create GitHub release
./.agent/scripts/version-manager.sh release [major|minor|patch]
```

This handles steps 1-7 automatically.

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

### 3. Update Changelog

See `workflows/changelog.md` for detailed guidance. The release command will fail if changelog is empty.

```bash
# Preview changelog entry from commits
./.agent/scripts/version-manager.sh changelog-preview

# Validate changelog matches version
./.agent/scripts/version-manager.sh changelog-check
```

Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- New feature description (#PR)

### Changed
- Changed behavior description (#PR)

### Fixed
- Bug fix description (#PR)
```

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
