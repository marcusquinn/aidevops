---
description: Refactor branch for code restructuring without behavior change
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Refactor Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `refactor/`
- **Example**: `refactor/extract-auth-service`, `refactor/simplify-api-layer`
- **Version bump**: Usually none (no behavior change) or patch
- **Key rule**: Same behavior, different structure

**Create**:

```bash
git checkout main && git pull origin main
git checkout -b refactor/{description}
```

**Commit pattern**: `refactor: description`

<!-- AI-CONTEXT-END -->

## When to Use

Use `refactor/` branches for:
- Code restructuring without behavior change
- Extracting reusable components
- Improving code organization
- Reducing technical debt
- Performance improvements (same behavior, faster)

**Not for**: Bug fixes (use `bugfix/`) or new features (use `feature/`).

## Branch Naming

```bash
# Describe what's being restructured
refactor/extract-auth-service
refactor/simplify-database-layer
refactor/consolidate-api-handlers
refactor/improve-error-handling
```

## Workflow

1. Create branch from updated `main`
2. **Ensure tests pass before starting**
3. Make structural changes
4. **Verify tests still pass** (critical!)
5. Commit with `refactor:` prefix
6. Push and create PR
7. Request thorough review (refactors can hide bugs)

## The Golden Rule

> **Same inputs → Same outputs**

If behavior changes, it's not a refactor. Either:
- Split into separate `bugfix/` or `feature/` branch
- Document the intentional behavior change

## Commit Messages

```bash
refactor: extract authentication into dedicated service

- Move auth logic from UserController to AuthService
- No behavior changes
- All existing tests pass

This improves testability and separation of concerns.
```

## Testing Requirements

Refactors require **extra testing scrutiny**:

- [ ] All existing tests pass (mandatory)
- [ ] No new test failures
- [ ] Manual verification of key flows
- [ ] Performance not degraded (if applicable)

## Version Impact

Refactors typically have **no version bump** since behavior is unchanged.

Exceptions:
- **Patch bump**: If refactor includes performance improvements users would notice
- **Minor bump**: If refactor enables new capabilities (but then it's arguably a feature)

## Review Focus

PR reviewers should verify:
1. No behavior changes (unless documented)
2. Tests still pass
3. Code is actually cleaner/better
4. No hidden bugs introduced

## Related

- **Version bumping**: `workflows/version-bump.md`
- **Code review**: `workflows/code-review.md`
