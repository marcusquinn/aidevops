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

Always start from latest main:

```bash
git checkout main && git pull origin main
git checkout -b fix/bug-description
# Include issue number when available: fix/123-plugin-activation-error
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

```markdown
## [Unreleased]
### Fixed
- Fixed issue where X caused Y (#123)
```

Update README/docs if fix affects user-facing functionality.

### 5. Testing

- [ ] Bug is fixed
- [ ] No regression in related functionality
- [ ] Latest and minimum supported versions tested
- [ ] Automated test suite passes
- [ ] Quality checks pass

```bash
npm test && composer test
bash ~/Git/aidevops/.agents/scripts/linters-local.sh
```

#### Frontend Bug Verification (CRITICAL)

HTTP status codes do NOT verify frontend fixes. Server returns 200 even when React crashes client-side (error boundaries render successfully; crash happens during hydration which curl never executes).

```bash
# BAD: returns 200 even when React crashes
curl -s https://myapp.local -o /dev/null -w "%{http_code}"

# GOOD: use browser screenshot
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
```

See `tools/ui/frontend-debugging.md` for browser verification workflow.

### 6. Commit

```bash
git add .
git commit -m "Fix #123: Brief description

- What was wrong
- How this fixes it
- Side effects or considerations"
```

### 7. Version Increment

| Increment | When | Example |
|-----------|------|---------|
| **PATCH** | Most bug fixes (no functionality change) | 1.6.0 → 1.6.1 |
| **MINOR** | Bug fix with new features or significant changes | 1.6.0 → 1.7.0 |
| **MAJOR** | Bug fix with breaking changes | 1.6.0 → 2.0.0 |

Don't update version numbers during development — only when fix is confirmed working.

### 8. Prepare Release

```bash
git checkout -b v{MAJOR}.{MINOR}.{PATCH}
git merge fix/bug-description --no-ff
# Update version numbers in all required files
git add . && git commit -m "Version {VERSION} - Bug fix release"
```

---

## Hotfix Process

For critical bugs requiring immediate release.

```bash
# 1. Branch from tag
git tag -l "v*" --sort=-v:refname | head -5
git checkout v{MAJOR}.{MINOR}.{PATCH}
git checkout -b hotfix/v{MAJOR}.{MINOR}.{PATCH+1}

# 2. Apply minimal fix, then update PATCH version in:
#    - Main application file, CHANGELOG.md, README.md
#    - package.json / composer.json, localization files

# 3. Commit and tag
git add . && git commit -m "Hotfix: Critical bug description"
git tag -a v{MAJOR}.{MINOR}.{PATCH+1} -m "Hotfix release"

# 4. Push
git push origin hotfix/v{MAJOR}.{MINOR}.{PATCH+1}
git push origin v{MAJOR}.{MINOR}.{PATCH+1}

# 5. Merge to main
git checkout main
git merge hotfix/v{MAJOR}.{MINOR}.{PATCH+1} --no-ff
git push origin main
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

## Testing Previous Versions

```bash
git checkout v{MAJOR}.{MINOR}.{PATCH}
# Or: git checkout v{MAJOR}.{MINOR}.{PATCH} -b test/some-issue
```

## Rollback Procedure

```bash
git tag -l "*-stable" --sort=-v:refname | head -5
git checkout v{VERSION}-stable
git checkout -b fix/rollback-based-fix
# Apply corrected fix, test thoroughly, create new version when confirmed
```

---

## Completion Checklist

- [ ] Root cause identified and documented
- [ ] Fix is minimal and focused
- [ ] No new features introduced
- [ ] Regression tests added
- [ ] All existing tests pass
- [ ] Quality checks pass
- [ ] Documentation updated
- [ ] Changelog updated
- [ ] Ready for code review
