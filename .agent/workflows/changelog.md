---
description: Maintain CHANGELOG.md following Keep a Changelog format
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

# Changelog Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Format**: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- **Validate**: Check CHANGELOG.md matches VERSION file
- **Generate**: Create entry from commits since last tag
- **Sections**: Added, Changed, Fixed, Removed, Security, Deprecated
- **Trigger**: Called by @versioning before version bump completes
- **Related**: `@version-bump`, `@release`

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

## Writing Good Entries

- **User perspective**: Describe impact, not implementation details
- **Actionable**: What can users do now that they couldn't before?
- **Concise**: One line per change, expand only if necessary
- **Past tense**: "Added", "Fixed", "Removed" (not "Add", "Fix")

**Examples**:

- Good: "Added bulk export for usage metrics"
- Bad: "Refactored MetricsExporter class to support batch operations"
- Good: "Fixed login timeout on slow connections"
- Bad: "Updated auth.js to handle edge case"

## Validation

Before releasing, verify:

- Latest `## [X.Y.Z]` matches VERSION file
- Date format: YYYY-MM-DD
- Comparison links at bottom are updated

## Generating Entries from Commits

To preview a changelog entry from recent commits:

```bash
.agent/scripts/version-manager.sh changelog-preview
```

## Before Releasing

1. Create new version section with date: `## [X.Y.Z] - YYYY-MM-DD`
2. Add entries under appropriate subsections (Added, Changed, Fixed, etc.)
3. Update comparison links at bottom
4. Validate with `version-manager.sh changelog-check`

**Note**: If using `[Unreleased]` for ongoing work, move items from there to the new version section. Otherwise, add entries directly to the new section.

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
