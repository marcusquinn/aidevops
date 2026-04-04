---
description: Hotfix branch - urgent production fixes
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hotfix Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `hotfix/` |
| **Commit** | `fix: [HOTFIX] description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create from** | **Latest tag** (not `main`) — fix matches production, not unreleased changes |
| **Urgency** | Immediate; can bypass normal review if authorized |

```bash
git fetch --tags
git checkout $(git describe --tags --abbrev=0)
git checkout -b hotfix/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- Critical production bugs, security vulnerabilities, data corruption, service outages

If it can wait for the normal release cycle, use `bugfix/` instead.

## Workflow

1. Apply the minimal fix only.
2. Test immediately.
3. Fast-track review, or deploy directly if authorized.
4. Merge back to `main` and push.

```bash
git checkout main && git pull origin main
git merge hotfix/critical-issue && git push origin main
```

### After Deployment

- [ ] Add regression tests
- [ ] Document the incident
- [ ] Review how the issue escaped

## Examples

```bash
hotfix/critical-auth-bypass
hotfix/production-database-lock
hotfix/payment-processing-failure
```

```bash
fix: [HOTFIX] prevent authentication bypass

CRITICAL SECURITY FIX
- Add missing permission check
- Validate session token

Deploy immediately. Full audit to follow.
```
