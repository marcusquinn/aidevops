---
description: Refactor branch - code restructure, same behavior
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

# Refactor Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `refactor/` |
| **Commit** | `refactor: description` |
| **Version** | Usually none (no behavior change) |
| **Create from** | `main` |

```bash
git checkout main && git pull origin main
git checkout -b refactor/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- Code restructuring without behavior change
- Extracting reusable components, reducing technical debt
- Performance improvements (same behavior, faster)

**Not for**: Bug fixes (`bugfix/`) or new features (`feature/`).

## The Golden Rule

> **Same inputs → Same outputs**

If behavior changes: split into `bugfix/`/`feature/` or document the intentional change.

## Testing & Review

Refactors require extra scrutiny — all existing tests must pass before and after.

**Before starting and after each change:**

```bash
npm test  # or project-specific test command
```

**PR reviewers verify:**

1. No behavior changes (unless documented)
2. Tests still pass; no performance regression
3. Code is actually cleaner/better

## Examples

```bash
refactor/extract-auth-service
refactor/simplify-database-layer
refactor/consolidate-api-handlers
```

**Commit format:**

```bash
refactor: extract authentication into dedicated service

- Move auth logic from UserController to AuthService
- No behavior changes; all existing tests pass
```
