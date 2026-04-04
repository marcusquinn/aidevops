---
description: Maintain CHANGELOG.md following Keep a Changelog format
mode: subagent
tools: { read: true, write: true, edit: true, bash: true, glob: true, grep: true, webfetch: false, task: true }
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Changelog Workflow

- **Format**: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- **Sections**: Added, Changed, Fixed, Removed, Security, Deprecated
- **Trigger**: Called by @versioning before version bump completes
- **Related**: `@version-bump`, `@release`

```bash
.agents/scripts/version-manager.sh changelog-preview   # preview entry from commits
.agents/scripts/version-manager.sh changelog-check      # validate changelog matches VERSION
.agents/scripts/version-manager.sh release [major|minor|patch]  # full release (includes validation)
```

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

## Entry Rules

- User perspective, past tense, one line per change — impact not implementation
- Good: `"Added bulk export for usage metrics"` / Bad: `"Refactored MetricsExporter class"`

## Release Checklist

1. Create `## [X.Y.Z] - YYYY-MM-DD` section; move `[Unreleased]` items into it
2. Add entries under appropriate subsections
3. Update comparison links at bottom of CHANGELOG.md
4. Validate: `version-manager.sh changelog-check` (or use `release` — enforces this automatically; `--force` to bypass)

## Related

- `workflows/version-bump.md` — version bumping
- `workflows/release.md` — creating releases
