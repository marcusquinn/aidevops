---
description: Hotfix branch - urgent production fixes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

# Hotfix Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `hotfix/` |
| **Commit** | `fix: [HOTFIX] description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create from** | **Latest tag** (not `main`) |
| **Urgency** | Immediate; can bypass normal review if authorized |

```bash
git fetch --tags
git checkout $(git describe --tags --abbrev=0)
git checkout -b hotfix/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- Critical production bugs
- Security vulnerabilities
- Data corruption issues
- Service outages

If it can wait for the normal release cycle, use `bugfix/` instead.

## Workflow

### Branch from the Latest Tag

Hotfixes start from the latest tag so the fix matches production, not unreleased `main` changes.

### Keep the Scope Tight

1. Apply the minimal fix only.
2. Test immediately.
3. Fast-track review, or deploy directly if authorized.
4. Merge the deployed fix back to `main`.

### After Deployment

- [ ] Merge the fix to `main`
- [ ] Add regression tests
- [ ] Document the incident
- [ ] Review how the issue escaped

## Examples

```bash
hotfix/critical-auth-bypass
hotfix/production-database-lock
hotfix/payment-processing-failure
```

## Commit Example

```bash
fix: [HOTFIX] prevent authentication bypass

CRITICAL SECURITY FIX
- Add missing permission check
- Validate session token

Deploy immediately. Full audit to follow.
```

## Merge Back to Main

```bash
git checkout main
git pull origin main
git merge hotfix/critical-issue
git push origin main
```
