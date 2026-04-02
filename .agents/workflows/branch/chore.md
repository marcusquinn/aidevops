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

# Chore Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `chore/` |
| **Commit** | `chore:`, `docs:`, `ci:`, or `build:` |
| **Version** | Usually none |
| **Create from** | `main` |

```bash
git checkout main && git pull origin main
git checkout -b chore/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- Dependency, CI/CD, docs, build, and tooling maintenance
- Code formatting/linting fixes
- License or `.gitignore` updates

**Not for** behavior changes; use `feature/`, `bugfix/`, or `refactor/` instead.

## Commit Prefixes

Pick the narrowest prefix for the change:

| Prefix | Use for | Example |
|--------|---------|---------|
| `chore:` | General maintenance | `chore: update dependencies` |
| `docs:` | Documentation | `docs: improve installation instructions` |
| `ci:` | CI/CD changes | `ci: add dependency caching` |
| `build:` | Build system | `build: switch bundler to esbuild` |

## Branch Examples

```
chore/update-dependencies
chore/fix-github-actions
chore/configure-eslint
```
