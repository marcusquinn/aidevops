---
description: Feature branch - new functionality
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

# Feature Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `feature/` |
| **Commit** | `feat: description` |
| **Version** | Minor bump (1.0.0 → 1.1.0) |
| **Create from** | `main` |

```bash
git checkout main && git pull origin main
git checkout -b feature/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

- New functionality or integrations
- Significant capability expansion

**Not for** bug fixes, refactors, or docs/config-only work.

## Guidance

- Minor-version bump applies when the branch ships user-visible capability, not internal-only maintenance.
- For implementation patterns, see `workflows/feature-development.md`.

## Examples

```bash
feature/user-dashboard
feature/export-to-csv
```

```bash
feat: add user authentication
```
