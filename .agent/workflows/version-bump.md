# Version Bump Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Get version**: `./.agent/scripts/version-manager.sh get`
- **Bump**: `./.agent/scripts/version-manager.sh bump [major|minor|patch]`
- **Validate**: `./.agent/scripts/version-manager.sh validate`
- **Auto-bump**: `./.agent/scripts/auto-version-bump.sh "commit message"`
- **Files updated**: VERSION, README.md badge, sonar-project.properties, setup.sh
- **Commit patterns**: BREAKING/MAJOR (major), FEATURE/NEW (minor), FIX/PATCH (patch)
- **Skip patterns**: docs, style, test, chore, ci, WIP, SKIP VERSION
- **Full release**: See `workflows/release.md` for tagging and GitHub release
- **Changelog**: See `workflows/changelog.md` for changelog management

<!-- AI-CONTEXT-END -->

This workflow covers version number management only. For the complete release process (tagging, GitHub releases), see `workflows/release.md`. For changelog management, see `workflows/changelog.md`.

## Version Management Tools

### Primary Tool: version-manager.sh

- **Location**: `.agent/scripts/version-manager.sh`
- **Purpose**: Manual version control
- **Capabilities**: Version bumping, file updates, validation

### Automation Tool: auto-version-bump.sh

- **Location**: `.agent/scripts/auto-version-bump.sh`
- **Purpose**: Intelligent version detection from commit messages
- **Capabilities**: Automatic version bumping based on commit patterns

## Usage

### Get Current Version

```bash
./.agent/scripts/version-manager.sh get
```

### Bump Version

```bash
# Patch version (1.3.0 → 1.3.1)
./.agent/scripts/version-manager.sh bump patch

# Minor version (1.3.0 → 1.4.0)
./.agent/scripts/version-manager.sh bump minor

# Major version (1.3.0 → 2.0.0)
./.agent/scripts/version-manager.sh bump major
```

### Validate Version Consistency

```bash
# Validate current version consistency across all files
./.agent/scripts/version-manager.sh validate

# Or use the standalone validator
./.agent/scripts/validate-version-consistency.sh

# Validate specific version
./.agent/scripts/validate-version-consistency.sh 1.6.0
```

## Automatic Version Detection

### Commit Message Patterns

**MAJOR Version (Breaking Changes):**

- `BREAKING`, `MAJOR`, `💥`, `🚨 BREAKING`
- Example: `💥 BREAKING: Change API structure`

**MINOR Version (New Features):**

- `FEATURE`, `FEAT`, `NEW`, `ADD`, `✨`, `🚀`, `📦`, `🎯 NEW/ADD`
- Example: `✨ FEATURE: Add Agno integration`

**PATCH Version (Bug Fixes/Improvements):**

- `FIX`, `PATCH`, `BUG`, `IMPROVE`, `UPDATE`, `ENHANCE`, `🔧`, `🐛`, `📝`, `🎨`, `♻️`, `⚡`, `🔒`, `📊`
- Example: `🔧 FIX: Resolve badge display issue`

**SKIP Version Bump:**

- `docs`, `style`, `test`, `chore`, `ci`, `build`, `WIP`, `SKIP VERSION`, `NO VERSION`

### Usage

```bash
# Analyze commit message and bump version accordingly
./.agent/scripts/auto-version-bump.sh "🚀 FEATURE: Add new integration"
```

## Files Updated Automatically

When bumping versions, these files are updated:

1. **VERSION**: Central version file
2. **README.md**: Version badge
3. **sonar-project.properties**: SonarCloud version
4. **setup.sh**: Script version header

### Validation Coverage

- ✅ **VERSION file**: Central version source
- ✅ **README.md badge**: Version display badge
- ✅ **sonar-project.properties**: SonarCloud integration
- ✅ **setup.sh**: Script version header
- ⚠️ **Optional files**: Warns if missing but doesn't fail

## Semantic Versioning Rules

Follow [semver.org](https://semver.org/) specification:

- **MAJOR**: Breaking changes, API modifications, architectural changes
- **MINOR**: New features, service integrations, significant enhancements
- **PATCH**: Bug fixes, documentation updates, minor improvements

### Version Examples

| Change Type | Before | After |
|-------------|--------|-------|
| Bug fix | 1.0.0 | 1.0.1 |
| New feature | 1.0.0 | 1.1.0 |
| Breaking change | 1.0.0 | 2.0.0 |
| Pre-release | 1.0.0 | 2.0.0-alpha.1 |

## Configuration

### Environment Variables

```bash
# Custom version file location (optional)
export VERSION_FILE=/path/to/VERSION
```

### Customization

- Edit `version-manager.sh` to customize file update patterns
- Adjust commit message patterns in `auto-version-bump.sh`

## Troubleshooting

### Version File Not Found

```bash
# Ensure VERSION file exists in repository root
echo "1.0.0" > VERSION
```

### Permission Issues

```bash
# Fix script permissions
chmod +x .agent/scripts/*.sh
```

### Validation Failures

```bash
# Check current version
./.agent/scripts/version-manager.sh get

# Run validation to see which files are out of sync
./.agent/scripts/version-manager.sh validate
```

## Next Steps

After bumping the version:

1. **Update changelog** - See `workflows/changelog.md`
2. **Create release** - See `workflows/release.md` for:
   - Creating git tags
   - Pushing to remote
   - Creating GitHub/GitLab releases
   - Post-release tasks
