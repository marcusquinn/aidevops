---
description: Chore worktree ref - maintenance, docs, deps, config
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chore Worktree Ref

| Aspect | Value |
|--------|-------|
| **Worktree ref prefix** | `chore/` |
| **Commit** | `chore:`, `docs:`, `ci:`, or `build:` |
| **Version** | None |
| **Create linked worktree from** | `main` |
| **Examples** | `chore/update-dependencies`, `chore/fix-github-actions`, `chore/configure-eslint` |

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add chore/{description}
# Then cd into the linked worktree path printed by the helper before editing.
```

## When to Use

- Dependency, CI/CD, docs, build, and tooling maintenance
- Code formatting/linting fixes
- License or `.gitignore` updates

**Not for** behavior changes; use `feature/`, `bugfix/`, or `refactor/` instead.

## Commit Prefixes

| Prefix | Use for | Example |
|--------|---------|---------|
| `chore:` | General maintenance | `chore: update dependencies` |
| `docs:` | Documentation | `docs: improve installation instructions` |
| `ci:` | CI/CD changes | `ci: add dependency caching` |
| `build:` | Build system | `build: switch bundler to esbuild` |
