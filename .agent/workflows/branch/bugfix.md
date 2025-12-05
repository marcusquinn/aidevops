---
description: Bugfix branch creation and resolution workflow
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  list: true
  webfetch: false
---

# Bugfix Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `bugfix/`
- **Example**: `bugfix/login-timeout`, `bugfix/123-null-pointer`
- **Version bump**: Patch (1.0.0 → 1.0.1)
- **Detailed guide**: `workflows/bug-fixing.md`

**Create**:

```bash
git checkout main && git pull origin main
git checkout -b bugfix/{description}
```

**Commit pattern**: `fix: description`

<!-- AI-CONTEXT-END -->

## When to Use

Use `bugfix/` branches for:
- Non-urgent bug fixes
- Issues that can wait for normal release cycle
- Bugs found in development/staging

For urgent production issues, use `hotfix/` instead.

## Branch Naming

```bash
# With issue number
bugfix/123-login-timeout

# Descriptive
bugfix/null-pointer-in-checkout
bugfix/api-response-parsing
```

## Workflow

1. Create branch from updated `main`
2. Fix bug (see `workflows/bug-fixing.md`)
3. Add regression test
4. Commit with `fix:` prefix
5. Push and create PR
6. After merge, bump patch version

## Commit Messages

```bash
fix: resolve login timeout on slow connections

- Increase timeout from 5s to 30s
- Add retry logic with exponential backoff
- Improve error message for users

Fixes #123
```

## Version Impact

Bug fixes trigger **patch** version bump:
- `1.0.0` → `1.0.1`
- `2.3.1` → `2.3.2`

See `workflows/version-bump.md` for version management.

## Related

- **Detailed workflow**: `workflows/bug-fixing.md`
- **Urgent fixes**: `branch/hotfix.md`
- **Version bumping**: `workflows/version-bump.md`
