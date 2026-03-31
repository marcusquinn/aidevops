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

## Guidance

Pick the narrowest commit prefix for the change:

| Prefix | Use for |
|--------|---------|
| `chore:` | General maintenance |
| `docs:` | Documentation |
| `ci:` | CI/CD changes |
| `build:` | Build system |

## Commit Examples

```bash
chore: update dependencies

docs: improve installation instructions

ci: optimize GitHub Actions workflow

- Add dependency caching
- Run tests in parallel

build: switch bundler to esbuild
```

## Examples

```bash
chore/update-dependencies
chore/fix-github-actions
chore/add-codecov
chore/update-readme
chore/configure-eslint
```
