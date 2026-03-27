---
description: Guidance for developing new features in any codebase
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

# Feature Development Guide for AI Assistants

## Planning Before Development

| Complexity | Approach |
|------------|----------|
| Trivial (< 30 mins) | Start immediately |
| Small (30 mins - 2 hours) | Add to `TODO.md`, then start |
| Medium (2 hours - 1 day) | Add to `TODO.md` with notes |
| Large (1+ days) | Use `/create-prd` → `/generate-tasks` |
| Complex (multi-session) | Full `todo/PLANS.md` entry |

**Quick start**: `/plan-status` to see existing tasks and plans.
**Full planning workflow**: See `workflows/plans.md`.

## Feature Development Workflow

### 1. Create a Feature Branch

Always start from the latest main:

```bash
git checkout main && git pull origin main
git checkout -b feature/123-descriptive-name
```

### 2. Understand Requirements

Before implementing, confirm: what problem this solves, who uses it, acceptance criteria, edge cases, and dependencies.

### 3. Implement the Feature

- Follow project coding standards and existing patterns
- Ensure strings are translatable (if applicable)
- Add docblocks and comments for complex logic
- Consider performance and backward compatibility

### 4. Version Discipline

**During development:** Do NOT update version numbers. Focus on functionality.

**When feature is confirmed working:**

```bash
# MINOR increment for features
git checkout -b v{MAJOR}.{MINOR+1}.0

# Update version numbers in: main app file, package.json/composer.json,
# CHANGELOG.md, README, localization files
git commit -m "Version {VERSION} - Feature name"
git tag -a v{VERSION}-stable -m "Stable version {VERSION}"
```

### 5. Update Documentation

- **CHANGELOG.md**: Add entry under `## [Unreleased] / ### Added`
- **README.md**: Update feature list, usage instructions, screenshots if UI changed
- **Code**: Docblocks on new functions, document complex logic

### 6. Testing

- [ ] Feature works as specified
- [ ] Edge cases handled
- [ ] Error handling works
- [ ] Performance acceptable
- [ ] No regression in existing functionality
- [ ] Works in supported environments
- [ ] Accessibility requirements met (if UI)

```bash
npm test          # or: composer test
bash ~/Git/aidevops/.agents/scripts/linters-local.sh
```

### 7. Commit Changes

Atomic, well-documented commits:

```bash
git add .
git commit -m "Add: Feature description

- Implemented X functionality
- Added Y component
- Integrated with Z system

Closes #123"
```

## Code Standards

### Security

- Validate and sanitize all input; escape all output
- Use parameterized queries
- Implement proper authentication/authorization
- Follow principle of least privilege

### Performance

- Avoid N+1 queries; use caching where appropriate
- Lazy load when possible; profile before optimizing

## Feature Type Guidelines

| Type | Key requirements |
|------|-----------------|
| **API** | REST conventions, versioning, documented endpoints with request/response examples, consistent error handling |
| **UI** | Existing design patterns, accessibility, help text, responsive, i18n |
| **Backend** | Existing patterns, scalability, monitoring/logging, documented config, failure scenarios |
| **Integration** | Optional when possible, dependency checks, fallback behavior, documented requirements |

## Multi-Repository Workspaces

```bash
# Confirm correct repository
pwd && git remote -v

# Verify feature doesn't already exist
grep -r "feature-keyword" .
```

- Implement features appropriate for this specific project's architecture
- When inspired by another repo: note it's new, adapt to current architecture, document inspiration in comments

## Completing the Feature

1. **TODO.md**: Move task to Done section with date
2. **todo/PLANS.md**: Update status and outcomes (if applicable)
3. **CHANGELOG.md**: Add entry following `workflows/changelog.md` format

## Feature Development Checklist

- [ ] Requirements fully implemented
- [ ] Edge cases and error handling complete
- [ ] Tests written and passing
- [ ] Documentation updated (README, CHANGELOG, code comments)
- [ ] Quality checks pass (`linters-local.sh`)
- [ ] No regression in existing features
- [ ] Performance and security considerations addressed
- [ ] Accessibility requirements met (if UI)
- [ ] Planning files updated
