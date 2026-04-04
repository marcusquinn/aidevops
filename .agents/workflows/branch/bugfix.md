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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Bugfix Branch

| Aspect | Value |
|--------|-------|
| **Prefix** | `bugfix/` |
| **Commit** | `fix: description` |
| **Version** | Patch bump (1.0.0 → 1.0.1) |
| **Create from** | `main` |
| **Examples** | `bugfix/login-timeout`, `bugfix/123-null-pointer` |

```bash
git checkout main && git pull origin main
git checkout -b bugfix/{description}
```

## When to Use

- Non-urgent bug fixes (can wait for release cycle) or bugs found in dev/staging.
- **Not for** urgent production issues (use `hotfix/`).

## Rules

- **Regression test**: MANDATORY to prevent recurrence.
- **Scope**: Minimal changes only — no new features or refactoring.
- **Investigation**: See `workflows/bug-fixing.md`.

## Commit Format

```
fix: resolve login timeout on slow connections

- Increase timeout from 5s to 30s
- Add retry logic with exponential backoff

Fixes #123
```
