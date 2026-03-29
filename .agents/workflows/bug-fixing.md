---
description: Guidance for AI assistants to help with bug fixing workflows
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

# Bug Fixing Guide for AI Assistants

## Workflow

### 1. Create Branch

```bash
git checkout main && git pull origin main
git checkout -b fix/123-bug-description  # Include issue number
```

### 2. Understand the Bug

| Question | Why |
|----------|-----|
| Expected vs actual behavior | Defines goal and problem |
| Steps to reproduce | Enables testing |
| Impact | Prioritizes fix |
| Root cause | Prevents symptom-only fixes |

### 3. Fix

- Minimal changes only — no new features
- Maintain backward compatibility
- Comment explaining the fix
- Add regression tests

### 4. Update Documentation

Update CHANGELOG (`## [Unreleased] → ### Fixed`) and README/docs if fix affects user-facing functionality.

### 5. Testing

- [ ] Bug is fixed, no regression in related functionality
- [ ] Latest and minimum supported versions tested
- [ ] Automated test suite and quality checks pass

```bash
npm test && composer test
bash ~/Git/aidevops/.agents/scripts/linters-local.sh
```

**Frontend bugs (CRITICAL):** HTTP 200 does NOT verify frontend fixes — server returns 200 even when React crashes client-side. Use browser screenshot via `dev-browser-helper.sh start`. See `tools/ui/frontend-debugging.md`.

### 6. Commit

```bash
git add .
git commit -m "Fix #123: Brief description

- What was wrong
- How this fixes it"
```

### 7. Version Increment

| Increment | When |
|-----------|------|
| **PATCH** | Most bug fixes (no functionality change) |
| **MINOR** | Bug fix with new features or significant changes |
| **MAJOR** | Bug fix with breaking changes |

Don't update version numbers during development — only when fix is confirmed working.

### 8. Prepare Release

```bash
git checkout -b v{MAJOR}.{MINOR}.{PATCH}
git merge fix/bug-description --no-ff
# Update version numbers, commit: "Version {VERSION} - Bug fix release"
```

---

## Hotfix Process

For critical bugs requiring immediate release:

```bash
# 1. Branch from latest tag
git tag -l "v*" --sort=-v:refname | head -5
git checkout v{MAJOR}.{MINOR}.{PATCH}
git checkout -b hotfix/v{MAJOR}.{MINOR}.{PATCH+1}

# 2. Apply minimal fix, update PATCH version in:
#    main app file, CHANGELOG, README, package.json/composer.json, localization

# 3. Commit, tag, push
git add . && git commit -m "Hotfix: Critical bug description"
git tag -a v{MAJOR}.{MINOR}.{PATCH+1} -m "Hotfix release"
git push origin hotfix/v{MAJOR}.{MINOR}.{PATCH+1}
git push origin v{MAJOR}.{MINOR}.{PATCH+1}

# 4. Merge to main
git checkout main && git merge hotfix/v{MAJOR}.{MINOR}.{PATCH+1} --no-ff && git push origin main
```

---

## Common Bug Types

| Type | Fix Strategy |
|------|-------------|
| **Null/Undefined** | Safe access with fallback: `user?.name ?? 'Unknown'` |
| **Race Conditions** | async/await, locks/semaphores, initialization order |
| **Memory Leaks** | Clean up event listeners, clear timers, release references |
| **API/Network** | Error handling, retries with backoff, timeouts, response validation |
| **Security** | Validate/sanitize inputs, escape outputs, parameterized queries, check permissions |

---

## Version Testing & Rollback

```bash
# Test previous version
git checkout v{MAJOR}.{MINOR}.{PATCH}

# Rollback: find stable tag, branch, apply corrected fix
git tag -l "*-stable" --sort=-v:refname | head -5
git checkout v{VERSION}-stable -b fix/rollback-based-fix
```

---

## Completion Checklist

- [ ] Root cause identified and documented
- [ ] Fix is minimal, focused, no new features
- [ ] Regression tests added, all tests pass
- [ ] Quality checks pass, documentation updated
- [ ] Changelog updated, ready for code review
