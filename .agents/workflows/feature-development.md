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

## Planning

| Complexity | Approach |
|------------|----------|
| Trivial (< 30 mins) | Start immediately |
| Small (30 mins – 2 hours) | Add to `TODO.md`, then start |
| Medium (2 hours – 1 day) | Add to `TODO.md` with notes |
| Large (1+ days) | Use `/create-prd` → `/generate-tasks` |
| Complex (multi-session) | Full `todo/PLANS.md` entry |

See `workflows/plans.md` for the full planning workflow.

## Workflow

### 1. Branch

```bash
git checkout main && git pull origin main
git checkout -b feature/123-descriptive-name
```

### 2. Understand Requirements

Confirm before implementing: what problem this solves, who uses it, acceptance criteria, edge cases, and dependencies.

### 3. Implement

- Follow project coding standards and existing patterns
- Add docblocks and comments for complex logic
- Consider performance, backward compatibility, and i18n (if applicable)
- Validate and sanitize all input; escape all output; use parameterized queries

### 4. Version Discipline

Do NOT update version numbers during development. Version bump happens after the feature is confirmed working. See `workflows/changelog.md`.

### 5. Update Documentation

- **CHANGELOG.md**: Add entry under `## [Unreleased] / ### Added`
- **README.md**: Update if user-facing features change
- **Code**: Docblocks on new functions; document complex logic

### 6. Test

- [ ] Feature works as specified
- [ ] Edge cases and error handling work
- [ ] No regression in existing functionality
- [ ] Performance acceptable
- [ ] Accessibility requirements met (if UI)

```bash
npm test          # or: composer test
bash ~/.aidevops/agents/scripts/linters-local.sh
```

### 7. Commit

```bash
git add .
git commit -m "feat: short description

- What changed and why

Closes #123"
```

## Feature Type Guidelines

| Type | Key requirements |
|------|-----------------|
| **API** | REST conventions, versioning, documented endpoints, consistent error handling |
| **UI** | Existing design patterns, accessibility, responsive, i18n |
| **Backend** | Existing patterns, scalability, monitoring/logging, documented config |
| **Integration** | Optional when possible, dependency checks, fallback behavior |

## Completing the Feature

1. **TODO.md**: Move task to Done section with date
2. **todo/PLANS.md**: Update status and outcomes (if applicable)
3. **CHANGELOG.md**: Add entry following `workflows/changelog.md` format
4. Quality checks pass (`linters-local.sh`)
