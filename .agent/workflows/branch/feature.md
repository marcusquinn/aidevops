# Feature Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `feature/`
- **Example**: `feature/user-dashboard`, `feature/123-api-rate-limiting`
- **Version bump**: Minor (1.0.0 → 1.1.0)
- **Detailed guide**: `workflows/feature-development.md`

**Create**:
```bash
git checkout main && git pull origin main
git checkout -b feature/{description}
```

**Commit pattern**: `feat: description`

<!-- AI-CONTEXT-END -->

## When to Use

Use `feature/` branches for:
- New functionality
- New capabilities
- New integrations
- Significant enhancements

## Branch Naming

```bash
# With issue number
feature/123-user-authentication

# Descriptive
feature/export-to-csv
feature/api-rate-limiting
```

## Workflow

1. Create branch from updated `main`
2. Implement feature (see `workflows/feature-development.md`)
3. Commit with `feat:` prefix
4. Push and create PR
5. After merge, bump minor version

## Commit Messages

```bash
feat: add user authentication

- Implement OAuth2 flow
- Add session management
- Create login/logout endpoints

Closes #123
```

## Version Impact

Features trigger **minor** version bump:
- `1.0.0` → `1.1.0`
- `2.3.1` → `2.4.0`

See `workflows/version-bump.md` for version management.

## Related

- **Detailed workflow**: `workflows/feature-development.md`
- **Version bumping**: `workflows/version-bump.md`
- **Code review**: `workflows/code-review.md`
