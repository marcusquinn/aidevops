---
description: Maintain CHANGELOG.md following Keep a Changelog format
mode: subagent
tools: { read: true, write: true, edit: true, bash: true, glob: true, grep: true, webfetch: false, task: true }
---

# Changelog Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Format**: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- **Sections**: Added, Changed, Fixed, Removed, Security, Deprecated
- **Trigger**: Called by @versioning before version bump completes
- **Related**: `@version-bump`, `@release`

```bash
.agents/scripts/version-manager.sh changelog-preview   # preview entry from commits
.agents/scripts/version-manager.sh changelog-check      # validate changelog matches VERSION
.agents/scripts/version-manager.sh release [major|minor|patch]  # full release (includes validation)
```

<!-- AI-CONTEXT-END -->

## Format

```markdown
## [Unreleased]

## [X.Y.Z] - YYYY-MM-DD

### Added
### Changed
### Fixed
### Removed
### Security
### Deprecated

[Unreleased]: https://github.com/user/repo/compare/vX.Y.Z...HEAD
[X.Y.Z]: https://github.com/user/repo/compare/vA.B.C...vX.Y.Z
```

## Writing Good Entries

- **User perspective**: Describe impact, not implementation details
- **Actionable**: What can users do now that they couldn't before?
- **Concise**: One line per change; **past tense** ("Added", "Fixed", not "Add", "Fix")

Good: "Added bulk export for usage metrics" / "Fixed login timeout on slow connections"
Bad: "Refactored MetricsExporter class to support batch operations" / "Updated auth.js to handle edge case"

## Release Checklist

1. Create version section: `## [X.Y.Z] - YYYY-MM-DD`
2. Add entries under appropriate subsections (Added, Changed, Fixed, etc.)
3. If using `[Unreleased]`, move items to the new version section
4. Update comparison links at bottom of CHANGELOG.md
5. Validate: `version-manager.sh changelog-check`

`version-manager.sh release` enforces this — fails if changelog is out of sync (use `--force` to bypass) and updates comparison links automatically.

## Related Workflows

- **Version bumping**: `workflows/version-bump.md`
- **Creating releases**: `workflows/release.md`
