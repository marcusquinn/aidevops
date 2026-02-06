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

| Scenario | Action |
|----------|--------|
| Features ready for release | Create `release/X.Y.0` |
| Bug fixes accumulated | Create `release/X.Y.Z` (patch) |
| Breaking changes ready | Create `release/X+1.0.0` |
| Hotfix needed | Use `hotfix/` branch instead |

## Unique Guidance

### Version Selection

| Change Type | Version Bump | Example |
|-------------|--------------|---------|
| Bug fixes only | Patch | 1.2.3 → 1.2.4 |
| New features (backward compatible) | Minor | 1.2.3 → 1.3.0 |
| Breaking changes | Major | 1.2.3 → 2.0.0 |

### Release Lifecycle

1. **Create release branch**
2. **Update version files**: `.agents/scripts/version-manager.sh bump {type}`
3. **Update CHANGELOG.md**
4. **Final testing**: `.agents/scripts/linters-local.sh`
5. **Create PR to main**
6. **Merge and tag**
7. **Create GitHub release**
8. **Run postflight**

### Cherry-Picking (If Needed)

```bash
# List unmerged feature branches
git branch --no-merged main | grep -E "^  (feature|bugfix)/"

# Cherry-pick specific commits
git cherry-pick {commit-hash}
```

### Tag and Release

```bash
# After PR merged
git checkout main && git pull
git tag -a v{VERSION} -m "Release v{VERSION}"
git push origin v{VERSION}
gh release create v{VERSION} --generate-notes
```

## Difference from Hotfix

| Aspect | Release Branch | Hotfix Branch |
|--------|----------------|---------------|
| Urgency | Planned | Urgent |
| Source | `main` | Latest tag |
| Content | Multiple features/fixes | Single critical fix |
| Testing | Full test cycle | Minimal, focused |

## Related

- `workflows/version-bump.md` - Version file management
- `workflows/release.md` - Full release process
- `workflows/changelog.md` - Changelog format
- `workflows/postflight.md` - Post-release verification
