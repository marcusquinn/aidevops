---
description: Chore branch - maintenance, docs, deps, config
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

# Chore Branch

| Aspect | Value |
|--------|-------|
| **Prefix** | `chore/` |
| **Commit** | `chore:`, `docs:`, `ci:`, or `build:` |
| **Version** | None |
| **Create from** | `main` |
| **Examples** | `chore/update-dependencies`, `chore/fix-github-actions`, `chore/configure-eslint` |

```bash
git checkout main && git pull origin main
git checkout -b chore/{description}
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
