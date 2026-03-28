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
- **Manual step**: Update CHANGELOG.md `[Unreleased]` → `[X.X.X] - YYYY-MM-DD` BEFORE running release
- **Preflight**: Quality checks (`.agents/scripts/linters-local.sh`) run automatically; bypass with `--skip-preflight`

<!-- AI-CONTEXT-END -->

## Commands

| Command | Purpose |
|---------|---------|
| `get` | Display current version |
| `bump [type]` | Bump version, update all 6 files |
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

**DO NOT** manually edit any of these files — editing one leaves the others stale and causes CI failures.

## CHANGELOG.md (Manual Step)

CHANGELOG.md requires manual update before `release`. The script checks for `[Unreleased]` content but does NOT move it automatically.

1. Change `## [Unreleased]` → `## [X.X.X] - YYYY-MM-DD`
2. Add a new empty `## [Unreleased]` section above it

```markdown
## [Unreleased]

## [1.6.0] - 2025-06-05

### Added
- New feature X
```

Preview suggested entries: `.agents/scripts/version-manager.sh changelog-preview`

## Recommended Workflow

```bash
.agents/scripts/version-manager.sh validate          # 1. Fix inconsistencies first
# 2. Update CHANGELOG.md manually (see above)
.agents/scripts/version-manager.sh release patch     # 3. Bug fixes (or minor/major)
git push && git push --tags                          # 4. Push
```

## Semantic Versioning

Follow [semver.org](https://semver.org/):

| Type | When to Use | Example |
|------|-------------|---------|
| **patch** | Bug fixes, docs, minor improvements | 1.5.0 → 1.5.1 |
| **minor** | New features, service integrations | 1.5.0 → 1.6.0 |
| **major** | Breaking changes, API modifications | 1.5.0 → 2.0.0 |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Version inconsistency | `version-manager.sh validate` then `version-manager.sh bump patch` to re-sync |
| GitHub release failed | `gh auth status` → `gh auth login` if needed |
| Changelog check failed | Update CHANGELOG.md or `version-manager.sh release patch --force` |

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

## Related

- `workflows/changelog.md` — Changelog management
- `workflows/release.md` — Full release process
- `workflows/preflight.md` — Quality checks before release
