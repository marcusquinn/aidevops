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
| **Create from** | **Latest tag** (not main) |
| **Urgency** | Immediate - bypasses normal review if needed |

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

**If it can wait for normal release cycle**, use `bugfix/` instead.

## Unique Guidance

### Create from Latest Tag (Not Main)

This ensures the hotfix applies to what's actually in production:

```bash
git fetch --tags
git checkout $(git describe --tags --abbrev=0)
git checkout -b hotfix/critical-issue
```

### Expedited Process

1. Apply **minimal fix** - only what's needed
2. Test immediately
3. Fast-track review (or deploy directly if authorized)
4. **Merge back to main** after deployment

### Post-Hotfix Checklist

After deploying:
- [ ] Ensure fix is merged to `main`
- [ ] Create proper regression tests
- [ ] Document incident
- [ ] Review how issue was missed

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

After deployment:

```bash
git checkout main
git pull origin main
git merge hotfix/critical-issue
git push origin main
```
