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
- Extracting reusable components
- Improving code organization
- Reducing technical debt
- Performance improvements (same behavior, faster)

**Not for**: Bug fixes (use `bugfix/`) or new features (use `feature/`).

## The Golden Rule

> **Same inputs → Same outputs**

If behavior changes, it's not a refactor. Either:
- Split into separate `bugfix/` or `feature/` branch
- Document the intentional behavior change

## Unique Guidance

### Extra Testing Scrutiny

Refactors require **extra testing scrutiny**:

- [ ] All existing tests pass (mandatory)
- [ ] No new test failures
- [ ] Manual verification of key flows
- [ ] Performance not degraded (if applicable)

### Ensure Tests Pass Before Starting

```bash
npm test  # or project-specific test command
```

### PR Review Focus

Reviewers should verify:
1. No behavior changes (unless documented)
2. Tests still pass
3. Code is actually cleaner/better
4. No hidden bugs introduced

## Examples

```bash
refactor/extract-auth-service
refactor/simplify-database-layer
refactor/consolidate-api-handlers
```

## Commit Example

```bash
refactor: extract authentication into dedicated service

- Move auth logic from UserController to AuthService
- No behavior changes
- All existing tests pass

This improves testability and separation of concerns.
```
