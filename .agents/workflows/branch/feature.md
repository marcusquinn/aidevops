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
| **Source** | `main` |

```bash
git checkout main && git pull origin main
git checkout -b feature/{description}
```

<!-- AI-CONTEXT-END -->

## Usage

- **Use for**: New functionality, integrations, significant capability expansion.
- **Not for**: Bug fixes, refactors, docs, or config-only work.
- **Version**: Minor bump applies to user-visible capabilities, not internal maintenance.
- **Patterns**: See `workflows/feature-development.md`.

## Examples

```bash
feature/user-dashboard
feature/export-to-csv
```

```bash
feat: add user authentication
```
