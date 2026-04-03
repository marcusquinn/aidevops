---
description: Release branch - version preparation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

# Release Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `release/` |
| **Naming** | `release/{MAJOR}.{MINOR}.{PATCH}` |
| **Commit** | `chore(release): v{version}` |
| **Create from** | `main` (or latest stable) |
| **Merge to** | `main` via PR, then tag |

```bash
git checkout main && git pull origin main
git checkout -b release/1.2.0
```

<!-- AI-CONTEXT-END -->

## When to Create

| Scenario | Branch | Bump | vs Hotfix |
|----------|--------|------|-----------|
| Bug fixes accumulated | `release/X.Y.Z` | Patch | Planned; full test cycle |
| New features ready | `release/X.Y.0` | Minor | Planned; full test cycle |
| Breaking changes | `release/X+1.0.0` | Major | Planned; full test cycle |
| Urgent critical fix | Use `hotfix/` | — | Urgent; minimal testing |

## Release Lifecycle

```bash
# 1. Bump version and update changelog
version-manager.sh bump {patch|minor|major}
# Edit CHANGELOG.md

# 2. Run final checks
linters-local.sh

# 3. PR to main, merge, then tag and publish
git checkout main && git pull
git tag -a v{VERSION} -m "Release v{VERSION}"
git push origin v{VERSION}
gh release create v{VERSION} --generate-notes

# 4. Run postflight
```

## Related

- `workflows/version-bump.md` — version file management
- `workflows/release.md` — full release process
- `workflows/changelog.md` — changelog format
- `workflows/postflight.md` — post-release verification
