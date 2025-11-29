# Release Process Workflow

This document outlines the comprehensive process for preparing and publishing software releases with proper versioning, quality checks, and deployment.

## Release Workflow Overview

1. Plan the release scope
2. Create a release branch
3. Update version numbers
4. Run code quality checks
5. Build and test
6. Update changelog and documentation
7. Commit version changes
8. Create version tags
9. Push to remote repositories
10. Create GitHub/GitLab release
11. Merge into main branch
12. Post-release tasks

## Pre-Release Planning

### Release Types

| Type | Version Change | Description |
|------|---------------|-------------|
| **Major** | X.0.0 | Breaking changes, major features |
| **Minor** | x.X.0 | New features, backward compatible |
| **Patch** | x.x.X | Bug fixes, security patches |
| **Hotfix** | x.x.X | Emergency production fixes |

### Release Checklist

Before starting a release:

- [ ] All planned features are merged
- [ ] All critical bugs are resolved
- [ ] CI/CD pipelines are passing
- [ ] Documentation is up to date
- [ ] Dependencies are updated and audited
- [ ] Security vulnerabilities addressed

## Detailed Release Steps

### 1. Create a Release Branch

Always start from an up-to-date main branch:

```bash
# Ensure main is current
git checkout main
git pull origin main  # Critical - never skip this

# Create release branch
git checkout -b release/v{MAJOR}.{MINOR}.{PATCH}

# Or for hotfixes
git checkout -b hotfix/v{MAJOR}.{MINOR}.{PATCH}
```

### 2. Update Version Numbers

Update version in all relevant files:

**JavaScript/Node.js Projects:**

```bash
# package.json
npm version {MAJOR}.{MINOR}.{PATCH} --no-git-tag-version

# Or manually update:
# - package.json: "version": "X.Y.Z"
# - package-lock.json: auto-updated
```

**Python Projects:**

```python
# setup.py or pyproject.toml
version = "X.Y.Z"

# __init__.py
__version__ = "X.Y.Z"
```

**Go Projects:**

```go
// version.go
const Version = "X.Y.Z"
```

**PHP Projects:**

```php
// Main plugin/application file
define('VERSION', 'X.Y.Z');

// Or in header comment
* Version: X.Y.Z
```

### 3. Run Code Quality Checks

Before proceeding, ensure all quality checks pass:

```bash
# Linting
npm run lint        # JavaScript/TypeScript
flake8 .            # Python
go vet ./...        # Go
composer phpcs      # PHP

# Type checking
npm run typecheck   # TypeScript
mypy .              # Python
go build ./...      # Go

# Unit tests
npm test
pytest
go test ./...
composer test

# Integration tests
npm run test:integration
pytest tests/integration/

# Security audit
npm audit
safety check        # Python
go mod verify       # Go
composer audit      # PHP
```

### 4. Build and Test

Build the release artifacts:

```bash
# JavaScript/TypeScript
npm run build
npm run build:production

# Python
python -m build
python setup.py sdist bdist_wheel

# Go
go build -ldflags "-X main.Version={VERSION}" ./...

# Docker
docker build -t project:v{VERSION} .
```

Test the built artifacts:

```bash
# Install and test locally
npm pack && npm install ./project-{VERSION}.tgz
pip install dist/project-{VERSION}.whl

# Run smoke tests
npm run test:smoke
pytest tests/smoke/
```

### 5. Update Changelog

Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
# Changelog

## [X.Y.Z] - YYYY-MM-DD

### Added
- New feature description (#PR)

### Changed
- Changed behavior description (#PR)

### Fixed
- Bug fix description (#PR)

### Security
- Security fix description (#PR)

### Deprecated
- Deprecated feature notice

### Removed
- Removed feature notice
```

### 6. Commit Version Changes

```bash
# Stage all version-related changes
git add -A

# Commit with descriptive message
git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}

- Update version numbers
- Update changelog
- Update documentation"
```

### 7. Create Version Tags

```bash
# Create annotated tag
git tag -a v{MAJOR}.{MINOR}.{PATCH} -m "Release v{MAJOR}.{MINOR}.{PATCH}

## Highlights
- Key feature or fix 1
- Key feature or fix 2

See CHANGELOG.md for full details."

# For projects using stable tags
git tag -a v{MAJOR}.{MINOR}.{PATCH}-stable -m "Stable release v{MAJOR}.{MINOR}.{PATCH}"
```

### 8. Push to Remote

```bash
# Check for existing tags
git ls-remote --tags origin

# If tags need to be replaced (use with caution)
git push origin --delete v{MAJOR}.{MINOR}.{PATCH}

# Push branch and tags
git push origin release/v{MAJOR}.{MINOR}.{PATCH}
git push origin --tags

# For multiple remotes
git push github release/v{MAJOR}.{MINOR}.{PATCH} --tags
git push gitlab release/v{MAJOR}.{MINOR}.{PATCH} --tags
```

### 9. Create GitHub/GitLab Release

**Using GitHub CLI:**

```bash
gh release create v{MAJOR}.{MINOR}.{PATCH} \
  --title "v{MAJOR}.{MINOR}.{PATCH}" \
  --notes-file RELEASE_NOTES.md \
  ./dist/*
```

**Using GitLab CLI:**

```bash
glab release create v{MAJOR}.{MINOR}.{PATCH} \
  --name "v{MAJOR}.{MINOR}.{PATCH}" \
  --notes-file RELEASE_NOTES.md \
  ./dist/*
```

### 10. Merge into Main

```bash
# Merge release branch
git checkout main
git merge release/v{MAJOR}.{MINOR}.{PATCH} --no-ff \
  -m "Merge release v{MAJOR}.{MINOR}.{PATCH} into main"

# Push to all remotes
git push origin main
git push github main
git push gitlab main
```

### 11. Clean Up

```bash
# Delete local release branch
git branch -d release/v{MAJOR}.{MINOR}.{PATCH}

# Delete remote release branch (optional)
git push origin --delete release/v{MAJOR}.{MINOR}.{PATCH}
```

## Post-Release Tasks

### Immediate Tasks

1. **Verify release artifacts**: Check all download links work
2. **Update documentation site**: Deploy updated docs
3. **Notify stakeholders**: Send release announcement
4. **Monitor for issues**: Watch for bug reports

### Follow-up Tasks

1. **Update dependent projects**: Bump version in downstream projects
2. **Close release milestone**: Mark milestone as complete
3. **Start next version**: Create new milestone and branch
4. **Update roadmap**: Reflect completed work

## Version Numbering Guidelines

### Semantic Versioning (SemVer)

Follow [semver.org](https://semver.org/) specification:

- **MAJOR**: Incompatible API changes
- **MINOR**: Add functionality in backward-compatible manner
- **PATCH**: Backward-compatible bug fixes

### Version Examples

| Change Type | Before | After |
|-------------|--------|-------|
| Bug fix | 1.0.0 | 1.0.1 |
| New feature | 1.0.0 | 1.1.0 |
| Breaking change | 1.0.0 | 2.0.0 |
| Pre-release | 1.0.0 | 2.0.0-alpha.1 |
| Build metadata | 1.0.0 | 1.0.0+build.123 |

### Pre-release Versions

```text
1.0.0-alpha.1    # Alpha release
1.0.0-beta.1     # Beta release
1.0.0-rc.1       # Release candidate
```

## Automated Release with CI/CD

### GitHub Actions Example

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

### GitLab CI Example

```yaml
release:
  stage: deploy
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/
  script:
    - npm run build
  release:
    tag_name: $CI_COMMIT_TAG
    description: 'Release $CI_COMMIT_TAG'
```

## Rollback Procedures

If a release needs to be rolled back:

### 1. Identify the Issue

```bash
# Check recent commits
git log --oneline -10

# Identify problematic changes
git diff v{PREVIOUS} v{CURRENT}
```

### 2. Create Hotfix or Revert

**Option A: Hotfix**

```bash
git checkout -b hotfix/v{NEW_PATCH}
# Fix the issue
git commit -m "fix: resolve critical issue from v{CURRENT}"
```

**Option B: Revert**

```bash
git revert <commit-hash>
git commit -m "revert: rollback problematic changes from v{CURRENT}"
```

### 3. Deploy Rollback

```bash
# Tag the rollback
git tag -a v{ROLLBACK} -m "Rollback release"
git push origin v{ROLLBACK}
```

## Release Communication Template

### Release Announcement

```markdown
# [Project Name] v{X.Y.Z} Released

We're excited to announce the release of [Project Name] v{X.Y.Z}!

## Highlights
- Feature 1: Description
- Feature 2: Description
- Bug fix: Description

## Breaking Changes
- Description of any breaking changes

## Upgrade Guide
1. Step to upgrade
2. Migration notes

## Download
- [GitHub Release](link)
- [npm](link)
- [PyPI](link)

## Full Changelog
See [CHANGELOG.md](link) for complete details.

## Thanks
Thanks to all contributors who made this release possible!
```

## Troubleshooting

### Tag Already Exists

```bash
# Delete and recreate local tag
git tag -d v{VERSION}
git tag -a v{VERSION} -m "Release v{VERSION}"

# Force push (use with caution)
git push origin v{VERSION} --force
```

### Failed CI/CD Pipeline

1. Check build logs for errors
2. Fix issues in release branch
3. Re-tag after fixing:

   ```bash
   git tag -d v{VERSION}
   git tag -a v{VERSION} -m "Release v{VERSION}"
   git push origin --delete v{VERSION}
   git push origin v{VERSION}
   ```

### Version Mismatch

If version numbers are inconsistent:

```bash
# Find all version references
grep -r "version" --include="*.json" --include="*.py" --include="*.go"

# Update all to match
```
