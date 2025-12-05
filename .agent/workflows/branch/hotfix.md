---
description: Urgent hotfix branch for critical production issues
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

# Hotfix Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `hotfix/`
- **Example**: `hotfix/critical-auth-bypass`, `hotfix/production-crash`
- **Version bump**: Patch (1.0.0 → 1.0.1)
- **Urgency**: Immediate - bypasses normal PR review if needed
- **Detailed guide**: `workflows/bug-fixing.md` (Hotfix section)

**Create from latest tag**:

```bash
git fetch --tags
git checkout $(git describe --tags --abbrev=0)
git checkout -b hotfix/{description}
```

**Commit pattern**: `fix: [HOTFIX] description`

<!-- AI-CONTEXT-END -->

## When to Use

Use `hotfix/` branches for:
- Critical production bugs
- Security vulnerabilities
- Data corruption issues
- Service outages

If it can wait for normal release cycle, use `bugfix/` instead.

## Branch Naming

```bash
# Descriptive of the critical issue
hotfix/critical-auth-bypass
hotfix/production-database-lock
hotfix/payment-processing-failure
```

## Workflow

Hotfixes have an expedited process:

1. **Create from latest release tag** (not main)

   ```bash
   git fetch --tags
   git checkout $(git describe --tags --abbrev=0)
   git checkout -b hotfix/critical-issue
   ```

2. **Apply minimal fix** - only what's needed

3. **Test immediately** - verify fix works

4. **Commit with HOTFIX marker**

   ```bash
   git commit -m "fix: [HOTFIX] critical auth bypass

   - Patch authentication check
   - Add input validation

   CRITICAL: Deploy immediately"
   ```

5. **Push and fast-track review** (or deploy directly if authorized)

6. **Merge to main after deployment**

   ```bash
   git checkout main
   git pull origin main
   git merge hotfix/critical-issue
   git push origin main
   ```

## Commit Messages

```bash
fix: [HOTFIX] prevent authentication bypass

CRITICAL SECURITY FIX
- Add missing permission check
- Validate session token

Deploy immediately. Full audit to follow.
```

## Version Impact

Hotfixes trigger **patch** version bump:
- `1.0.0` → `1.0.1`

Version is bumped immediately as part of the hotfix.

## Post-Hotfix

After deploying:
1. Ensure fix is merged to `main`
2. Create proper regression tests
3. Document incident
4. Review how issue was missed

## Related

- **Non-urgent fixes**: `branch/bugfix.md`
- **Detailed bug workflow**: `workflows/bug-fixing.md`
- **Version bumping**: `workflows/version-bump.md`
