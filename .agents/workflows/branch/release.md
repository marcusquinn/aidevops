---
description: Release worktree ref - version preparation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Worktree Ref

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `release/` |
| **Naming** | `release/{MAJOR}.{MINOR}.{PATCH}` |
| **Commit** | `chore(release): v{version}` |
| **Create linked worktree from** | `main` (or latest stable) |
| **Merge to** | `main` via PR, then tag |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add release/1.2.0
# Then cd into the linked worktree path printed by the helper before editing.
```

## When to Create

| Scenario | Bump | Note |
|----------|------|------|
| Bug fixes accumulated | Patch | Planned; full test cycle |
| New features ready | Minor | Planned; full test cycle |
| Breaking changes | Major | Planned; full test cycle |
| Urgent critical fix | — | Use `hotfix/` instead |

## Release Lifecycle

```bash
# 1. Bump version and update changelog
version-manager.sh bump {patch|minor|major}
# Edit CHANGELOG.md

# 2. Reuse terminal CI/lint evidence for the exact release SHA. Run a broad
# gate only when SHA-matched evidence is unavailable or shared/root contracts
# were not covered by affected checks:
# linters-local.sh --full

# 3. After implementation PRs merge, release from a fresh detached linked worktree
git worktree add --detach "$AIDEVOPS_WORKTREE_BASE_DIR/repo-release-1-2-0" origin/main
# Run version-manager.sh release from that printed worktree; never switch canonical HEAD.
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
