---
description: Release branch - version preparation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
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

| Scenario | Branch | vs Hotfix |
|----------|--------|-----------|
| Features ready | `release/X.Y.0` (minor) | Planned; full test cycle |
| Bug fixes accumulated | `release/X.Y.Z` (patch) | Planned; full test cycle |
| Breaking changes | `release/X+1.0.0` (major) | Planned; full test cycle |
| Urgent critical fix | Use `hotfix/` instead | Urgent; minimal testing |

## Version Selection

| Change Type | Bump | Example |
|-------------|------|---------|
| Bug fixes only | Patch | 1.2.3 → 1.2.4 |
| New features (backward compatible) | Minor | 1.2.3 → 1.3.0 |
| Breaking changes | Major | 1.2.3 → 2.0.0 |

## Release Lifecycle

1. Create release branch
2. `version-manager.sh bump {type}` — update version files
3. Update `CHANGELOG.md`
4. `linters-local.sh` — final testing
5. Create PR to `main`, merge and tag
6. `gh release create v{VERSION} --generate-notes`
7. Run postflight

```bash
# After PR merged — tag and publish
git checkout main && git pull
git tag -a v{VERSION} -m "Release v{VERSION}"
git push origin v{VERSION}
gh release create v{VERSION} --generate-notes
```

## Related

- `workflows/version-bump.md` — version file management
- `workflows/release.md` — full release process
- `workflows/changelog.md` — changelog format
- `workflows/postflight.md` — post-release verification
