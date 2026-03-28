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

- **Full release**: `.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight`
- **CRITICAL**: This single command does everything — bump, commit, tag, push, GitHub release
- **NEVER** run separate commands, manually edit VERSION, or bump versions yourself
- **Files updated atomically**: VERSION, package.json, README.md badge, setup.sh, sonar-project.properties, .claude-plugin/marketplace.json
- **Manual step**: Update CHANGELOG.md `[Unreleased]` to `[X.X.X] - YYYY-MM-DD` BEFORE running release
- **Preflight**: Quality checks run automatically (bypass with `--skip-preflight`)

<!-- AI-CONTEXT-END -->

## Critical: Never Edit VERSION Directly

**DO NOT** manually edit VERSION or any of the 6 version-tracked files. Editing one leaves the others stale and causes CI failures.

**Always use**:

```bash
.agents/scripts/version-manager.sh bump [major|minor|patch]
# or for full release:
.agents/scripts/version-manager.sh release [major|minor|patch]
```

## Command Reference

| Command | Purpose |
|---------|---------|
| `get` | Display current version |
| `bump [type]` | Bump version and update all 6 files |
| `validate` | Check version consistency across all files |
| `release [type]` | Full release: bump, validate, tag, GitHub release |
| `tag` | Create git tag for current version |
| `github-release` | Create GitHub release for current version |
| `changelog-check` | Verify CHANGELOG.md has entry for current version |
| `changelog-preview` | Generate changelog entries from commits |

### Release Options

```bash
.agents/scripts/version-manager.sh release patch              # standard (runs preflight, requires changelog)
.agents/scripts/version-manager.sh release minor --force      # bypass changelog check
.agents/scripts/version-manager.sh release patch --skip-preflight  # bypass preflight
.agents/scripts/version-manager.sh release patch --force --skip-preflight  # bypass both
```

## Files Updated Automatically

| File | What's Updated |
|------|----------------|
| `VERSION` | Plain version number (e.g., `1.6.0`) |
| `package.json` | `"version": "X.X.X"` field |
| `README.md` | Version badge: `Version-X.X.X-blue` |
| `setup.sh` | Header comment: `# Version: X.X.X` |
| `sonar-project.properties` | `sonar.projectVersion=X.X.X` |
| `.claude-plugin/marketplace.json` | `"version": "X.X.X"` field |

## CHANGELOG.md (Manual Step)

CHANGELOG.md requires manual update before running `release`. The script checks for content in `[Unreleased]` but does NOT move it automatically.

Before running release:

1. Change `## [Unreleased]` → `## [X.X.X] - YYYY-MM-DD`
2. Add a new empty `## [Unreleased]` section above it

```markdown
## [Unreleased]

## [1.6.0] - 2025-06-05

### Added
- New feature X
```

Preview suggested entries from commits:

```bash
.agents/scripts/version-manager.sh changelog-preview
```

## Recommended Workflow

```bash
# 1. Validate current state (fix inconsistencies first)
.agents/scripts/version-manager.sh validate

# 2. Update CHANGELOG.md manually (see above)

# 3. Run release
.agents/scripts/version-manager.sh release patch   # bug fixes
.agents/scripts/version-manager.sh release minor   # new features
.agents/scripts/version-manager.sh release major   # breaking changes

# 4. Push
git push && git push --tags
```

## Semantic Versioning Rules

Follow [semver.org](https://semver.org/):

| Type | When to Use | Example |
|------|-------------|---------|
| **patch** | Bug fixes, docs, minor improvements | 1.5.0 → 1.5.1 |
| **minor** | New features, service integrations | 1.5.0 → 1.6.0 |
| **major** | Breaking changes, API modifications | 1.5.0 → 2.0.0 |

## Preflight Quality Checks

The `release` command automatically runs `.agents/scripts/linters-local.sh`. Bypass with `--skip-preflight` (not recommended).

## Troubleshooting

**Version inconsistency:**

```bash
.agents/scripts/version-manager.sh validate
.agents/scripts/version-manager.sh bump patch  # re-sync all files
```

**GitHub release failed** — check auth:

```bash
gh auth status
gh auth login  # if needed
```

**Changelog check failed** — update CHANGELOG.md or bypass:

```bash
.agents/scripts/version-manager.sh release patch --force
```

## Related Workflows

- `workflows/changelog.md` — Changelog management
- `workflows/release.md` — Full release process
- `workflows/preflight.md` — Quality checks before release

## AI Decision-Making for Release Type

**Determine release type autonomously** — do not ask the user:

1. `git log v{LAST_TAG}..HEAD --oneline` — review commits since last release
2. Categorize: bug fix, feature, or breaking change
3. Apply semver — highest category wins

| Commit Prefix | Release Type |
|---------------|-------------|
| `feat:` | minor |
| `fix:`, `docs:`, `chore:`, `refactor:`, `perf:` | patch |
| `BREAKING CHANGE:` or `feat!:` / `fix!:` | major |
