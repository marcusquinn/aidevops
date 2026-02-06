---
description: Bugfix branch - non-urgent bug fixes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

# Bugfix Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `bugfix/` |
| **Commit** | `fix: description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create from** | `main` |

```bash
git checkout main && git pull origin main
git checkout -b bugfix/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- Non-urgent bug fixes
- Issues that can wait for normal release cycle
- Bugs found in development/staging

**For urgent production issues**, use `hotfix/` instead.

## Unique Guidance

**Always add a regression test** to prevent the bug from recurring.

For detailed bug investigation patterns, see `workflows/bug-fixing.md`.

## Examples

```bash
bugfix/login-timeout
bugfix/123-null-pointer
bugfix/api-response-parsing
```

## Commit Example

```bash
fix: resolve login timeout on slow connections

- Increase timeout from 5s to 30s
- Add retry logic with exponential backoff
- Improve error message for users

Fixes #123
```
