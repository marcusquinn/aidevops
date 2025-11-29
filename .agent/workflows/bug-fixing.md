# Bug Fixing Guide for AI Assistants

This document provides guidance for AI assistants to help with bug fixing workflows.

## Bug Fixing Workflow

### 1. Create a Bug Fix Branch

Always start from the latest main branch (mandatory):

```bash
git checkout main
git pull origin main
git checkout -b fix/bug-description
```

Use descriptive names that indicate what bug is being fixed. Include issue numbers when available:

```bash
git checkout -b fix/123-plugin-activation-error
git checkout -b fix/api-timeout-handling
git checkout -b fix/null-pointer-exception
```

### 2. Understand the Bug

Before fixing, understand:

| Question | Why It Matters |
|----------|----------------|
| What is the expected behavior? | Defines the goal |
| What is the actual behavior? | Clarifies the problem |
| Steps to reproduce? | Enables testing |
| What is the impact? | Prioritizes the fix |
| What is the root cause? | Prevents symptom-only fixes |

### 3. Fix the Bug

When implementing the fix:

- Make **minimal changes** necessary to fix the bug
- **Avoid introducing new features** while fixing bugs
- **Maintain backward compatibility**
- Add appropriate **comments explaining the fix**
- Consider adding **tests to prevent regression**

### 4. Update Documentation

Update relevant documentation:

```markdown
# CHANGELOG.md - Add under "Unreleased" section
## [Unreleased]
### Fixed
- Fixed issue where X caused Y (#123)
```

Update readme/docs if the bug fix affects user-facing functionality.

### 5. Testing

Test the fix thoroughly:

- [ ] Verify the bug is fixed
- [ ] Ensure no regression in related functionality
- [ ] Test with latest supported versions
- [ ] Test with minimum supported versions
- [ ] Run automated test suite
- [ ] Run quality checks

```bash
# Run tests
npm test
composer test

# Run quality checks
bash ~/git/aidevops/.agent/scripts/quality-check.sh
```

### 6. Commit Changes

Make atomic commits with clear messages:

```bash
git add .
git commit -m "Fix #123: Brief description of the bug fix

- Detailed explanation of what was wrong
- How this commit fixes it
- Any side effects or considerations"
```

### 7. Version Determination

After fixing and confirming the fix works, determine version increment:

| Increment | When to Use | Example |
|-----------|-------------|---------|
| **PATCH** | Most bug fixes (no functionality change) | 1.6.0 -> 1.6.1 |
| **MINOR** | Bug fixes with new features or significant changes | 1.6.0 -> 1.7.0 |
| **MAJOR** | Bug fixes with breaking changes | 1.6.0 -> 2.0.0 |

**Important:** Don't update version numbers during development. Only create version branches when the fix is confirmed working.

### 8. Prepare for Release

When ready for release:

```bash
# Create version branch
git checkout -b v{MAJOR}.{MINOR}.{PATCH}

# Merge fix branch
git merge fix/bug-description --no-ff

# Update version numbers in all required files
# Commit version updates
git add .
git commit -m "Version {VERSION} - Bug fix release"
```

## Hotfix Process

For critical bugs requiring immediate release:

### 1. Create Hotfix Branch from Tag

```bash
# Find the current release tag
git tag -l "v*" --sort=-v:refname | head -5

# Create hotfix branch from that tag
git checkout v{MAJOR}.{MINOR}.{PATCH}
git checkout -b hotfix/v{MAJOR}.{MINOR}.{PATCH+1}
```

### 2. Apply Minimal Fix

Apply only the essential fix for the critical issue.

### 3. Update Version Numbers

Increment PATCH version in all files:

- Main application file (version constant/header)
- CHANGELOG.md
- README.md / readme.txt
- Package files (package.json, composer.json)
- Language/localization files if applicable

### 4. Commit and Tag

```bash
git add .
git commit -m "Hotfix: Critical bug description"
git tag -a v{MAJOR}.{MINOR}.{PATCH+1} -m "Hotfix release"
```

### 5. Push Hotfix

```bash
git push origin hotfix/v{MAJOR}.{MINOR}.{PATCH+1}
git push origin v{MAJOR}.{MINOR}.{PATCH+1}
```

### 6. Merge to Main

```bash
git checkout main
git merge hotfix/v{MAJOR}.{MINOR}.{PATCH+1} --no-ff
git push origin main
```

## Common Bug Types and Strategies

### Null/Undefined Errors

```javascript
// Before: Crashes if user is null
const name = user.name;

// After: Safe access with fallback
const name = user?.name ?? 'Unknown';
```

### Race Conditions

- Add proper async/await handling
- Use locks or semaphores where needed
- Ensure proper initialization order

### Memory Leaks

- Clean up event listeners
- Clear timers and intervals
- Release references when done

### API/Network Errors

- Add proper error handling
- Implement retries with backoff
- Add timeout handling
- Validate responses before use

### Security Issues

- Validate and sanitize all inputs
- Escape all outputs
- Use parameterized queries
- Check permissions/capabilities

## Testing Previous Versions

To test against a previous version:

```bash
# Checkout specific tag
git checkout v{MAJOR}.{MINOR}.{PATCH}

# Or create test branch from tag
git checkout v{MAJOR}.{MINOR}.{PATCH} -b test/some-issue
```

## Rollback Procedure

If a fix causes issues after release:

```bash
# Find last stable version
git tag -l "*-stable" --sort=-v:refname | head -5

# Create fix branch from stable
git checkout v{VERSION}-stable
git checkout -b fix/rollback-based-fix

# Apply corrected fix
# Test thoroughly
# Create new version when confirmed
```

## Bug Fix Checklist

Before marking a bug fix as complete:

- [ ] Root cause identified and documented
- [ ] Fix is minimal and focused
- [ ] No new features introduced
- [ ] Tests added to prevent regression
- [ ] All existing tests pass
- [ ] Quality checks pass
- [ ] Documentation updated
- [ ] Changelog updated
- [ ] Ready for code review
