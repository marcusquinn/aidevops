---
description: Authoritative guide for version management in aidevops
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

# Version Bump Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Full release**: `.agent/scripts/version-manager.sh release [major|minor|patch] --skip-preflight`
- **CRITICAL**: This single command does everything - bump, commit, tag, push, GitHub release
- **NEVER** run separate commands, manually edit VERSION, or bump versions yourself
- **Files updated atomically**: VERSION, package.json, README.md badge, setup.sh, sonar-project.properties
- **Manual step**: Update CHANGELOG.md `[Unreleased]` to `[X.X.X] - YYYY-MM-DD` BEFORE running release
- **Preflight**: Quality checks run automatically (bypass with `--skip-preflight`)

<!-- AI-CONTEXT-END -->

This is the authoritative guide for AI agents performing version bumps in the aidevops repository.

## Critical: Never Edit VERSION Directly

**DO NOT** manually edit the VERSION file. This causes version inconsistencies and CI failures.

The script updates 5 files atomically:
1. VERSION
2. README.md (badge)
3. sonar-project.properties
4. setup.sh (header comment)
5. package.json

If you edit VERSION directly, the other 4 files become stale.

**Always use**:

```bash
.agent/scripts/version-manager.sh bump [major|minor|patch]
# or for full release:
.agent/scripts/version-manager.sh release [major|minor|patch]
```

## The Primary Tool: version-manager.sh

**Location**: `.agent/scripts/version-manager.sh`

This script handles all version management tasks:

- Bumps semantic versions (major/minor/patch)
- Updates version references across 5 files
- Validates version consistency
- Creates git tags
- Creates GitHub releases (via `gh` CLI)
- Runs preflight quality checks

## Complete Command Reference

| Command | Purpose |
|---------|---------|
| `get` | Display current version from VERSION file |
| `bump [type]` | Bump version and update all files |
| `validate` | Check version consistency across all files |
| `release [type]` | Full release: bump, validate, tag, GitHub release |
| `tag` | Create git tag for current version |
| `github-release` | Create GitHub release for current version |
| `changelog-check` | Verify CHANGELOG.md has entry for current version |
| `changelog-preview` | Generate changelog entries from commits |

### Release Options

```bash
# Standard release (runs preflight checks, requires changelog)
.agent/scripts/version-manager.sh release patch

# Bypass changelog check
.agent/scripts/version-manager.sh release minor --force

# Bypass preflight quality checks
.agent/scripts/version-manager.sh release patch --skip-preflight

# Bypass both
.agent/scripts/version-manager.sh release patch --force --skip-preflight
```

## Files Updated Automatically

The script updates these 5 files:

| File | What's Updated |
|------|----------------|
| `VERSION` | Plain version number (e.g., `1.6.0`) |
| `package.json` | `"version": "X.X.X"` field |
| `README.md` | Version badge: `Version-X.X.X-blue` |
| `setup.sh` | Header comment: `# Version: X.X.X` |
| `sonar-project.properties` | `sonar.projectVersion=X.X.X` |

## The CHANGELOG.md Gap

**CHANGELOG.md requires manual update before running `release`.**

The script checks for content in `[Unreleased]` but does NOT automatically move it to a versioned section.

### Before Running Release

1. Open `CHANGELOG.md`
2. Change `## [Unreleased]` to `## [X.X.X] - YYYY-MM-DD`
3. Add a new empty `## [Unreleased]` section above it
4. Then run the release command

### Example CHANGELOG Update

Before:

```markdown
## [Unreleased]

### Added
- New feature X
```

After (for version 1.6.0):

```markdown
## [Unreleased]

## [1.6.0] - 2025-06-05

### Added
- New feature X
```

### Generating Changelog Content

```bash
# Preview suggested changelog entries from commits
.agent/scripts/version-manager.sh changelog-preview
```

## Recommended Workflow

### Step 1: Validate Current State

```bash
.agent/scripts/version-manager.sh validate
```

This catches stale versions before you start. Fix any inconsistencies first.

### Step 2: Update CHANGELOG.md

Manually update the changelog (see gap section above).

### Step 3: Run Release

```bash
# For bug fixes
.agent/scripts/version-manager.sh release patch

# For new features
.agent/scripts/version-manager.sh release minor

# For breaking changes
.agent/scripts/version-manager.sh release major
```

### Step 4: Push Changes

```bash
git push && git push --tags
```

## Semantic Versioning Rules

Follow [semver.org](https://semver.org/):

| Type | When to Use | Example |
|------|-------------|---------|
| **patch** | Bug fixes, docs, minor improvements | 1.5.0 -> 1.5.1 |
| **minor** | New features, service integrations | 1.5.0 -> 1.6.0 |
| **major** | Breaking changes, API modifications | 1.5.0 -> 2.0.0 |

## Validation Details

The `validate` command checks:

- VERSION file exists and contains expected version
- README.md badge contains `Version-X.X.X-blue`
- sonar-project.properties contains `sonar.projectVersion=X.X.X`
- setup.sh contains `# Version: X.X.X`

```bash
# Example output
[INFO] Validating version consistency across files...
[SUCCESS] VERSION file: 1.5.0 ✓
[SUCCESS] README.md badge: 1.5.0 ✓
[SUCCESS] sonar-project.properties: 1.5.0 ✓
[SUCCESS] setup.sh: 1.5.0 ✓
[SUCCESS] All version references are consistent: 1.5.0
```

## Preflight Quality Checks

The `release` command automatically runs `.agent/scripts/linters-local.sh` before proceeding.

To bypass (not recommended):

```bash
.agent/scripts/version-manager.sh release patch --skip-preflight
```

## Troubleshooting

### Version Inconsistency Detected

```bash
# See which files are out of sync
.agent/scripts/version-manager.sh validate

# Sync all files to current VERSION
.agent/scripts/version-manager.sh bump patch  # or use sync if available
```

### GitHub Release Failed

Ensure GitHub CLI is authenticated:

```bash
gh auth status
gh auth login  # if needed
```

### Changelog Check Failed

Either update CHANGELOG.md or bypass:

```bash
.agent/scripts/version-manager.sh release patch --force
```

## Related Workflows

- `workflows/changelog.md` - Changelog management details
- `workflows/release.md` - Full release process
- `workflows/preflight.md` - Quality checks before release

## AI Decision-Making for Release Type

When performing releases, **determine the release type autonomously** by analyzing the changes:

1. Review commits since last release: `git log v{LAST_TAG}..HEAD --oneline`
2. Categorize each change: bug fix, feature, or breaking change
3. Apply semver rules - highest category wins:
   - Any breaking change → `major`
   - Any new feature (no breaking) → `minor`
   - Only fixes/docs/improvements → `patch`
4. State your analysis briefly and proceed with the release

**Do not ask the user** to choose patch/minor/major. The semver rules are deterministic - apply them based on the actual changes made.

### Change Type Indicators

| Commit Prefix | Type | Release |
|---------------|------|---------|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `docs:` | Documentation | patch |
| `chore:` | Maintenance | patch |
| `refactor:` | Code restructure | patch |
| `perf:` | Performance | patch |
| `BREAKING CHANGE:` | Breaking | major |
| `!` after type (e.g., `feat!:`) | Breaking | major |
