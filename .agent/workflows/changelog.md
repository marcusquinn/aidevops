# Changelog Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Format**: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- **Validate**: Check CHANGELOG.md matches VERSION file
- **Generate**: Create entry from commits since last tag
- **Sections**: Added, Changed, Fixed, Removed, Security, Deprecated
- **Trigger**: Called by @versioning before version bump completes

**Commands**:

```bash
# Preview changelog entry from commits
.agent/scripts/version-manager.sh changelog-preview

# Validate changelog matches version
.agent/scripts/version-manager.sh changelog-check

# Full release (includes changelog validation)
.agent/scripts/version-manager.sh release [major|minor|patch]
```

<!-- AI-CONTEXT-END -->

## Changelog Format

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format:

```markdown
## [Unreleased]

## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes to existing functionality

### Fixed
- Bug fixes

### Removed
- Removed features

### Security
- Security fixes

### Deprecated
- Soon-to-be removed features
```

## Commit Type to Section Mapping

| Commit Prefix | Changelog Section |
|---------------|-------------------|
| `feat:` | Added |
| `fix:` | Fixed |
| `refactor:` | Changed |
| `docs:` | Changed |
| `chore:` | Changed |
| `security:` | Security |
| `deprecate:` | Deprecated |
| `remove:` | Removed |

## Validation Rules

1. **Version Match**: Latest `## [X.Y.Z]` must match VERSION file
2. **Unreleased Section**: Must exist at top for ongoing work
3. **Date Format**: YYYY-MM-DD (ISO 8601)
4. **Link Format**: Comparison links at bottom must be valid

## Generating Entries

To generate a changelog entry from commits:

```bash
# Get commits since last tag
git log $(git describe --tags --abbrev=0)..HEAD --pretty=format:"- %s"

# Or use the helper
.agent/scripts/version-manager.sh changelog-preview
```

## Before Releasing

1. Move items from `[Unreleased]` to new version section
2. Add date to version header
3. Update comparison links at bottom
4. Validate with `version-manager.sh changelog-check`

## Link Format

At the bottom of CHANGELOG.md, maintain comparison links:

```markdown
[Unreleased]: https://github.com/user/repo/compare/vX.Y.Z...HEAD
[X.Y.Z]: https://github.com/user/repo/compare/vA.B.C...vX.Y.Z
```

## Integration with Versioning

The `version-manager.sh release` command:
1. Checks CHANGELOG has entry for new version (or `[Unreleased]` content)
2. Fails if changelog is out of sync (use `--force` to bypass)
3. Updates comparison links automatically

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Creating releases**: `workflows/release.md`
