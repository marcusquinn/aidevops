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

- New functionality or capabilities
- New integrations
- Significant enhancements

## Unique Guidance

For detailed feature implementation patterns, see `workflows/feature-development.md`.

## Examples

```bash
feature/user-dashboard
feature/123-api-rate-limiting
feature/export-to-csv
```

## Commit Example

```bash
feat: add user authentication

- Implement OAuth2 flow
- Add session management
- Create login/logout endpoints

Closes #123
```
