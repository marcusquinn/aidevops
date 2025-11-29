# Code Review Guide for AI Assistants

This document provides a comprehensive code review checklist for AI assistants reviewing any codebase.

## Code Review Checklist

### Functionality

- [ ] Does the code work as expected?
- [ ] Does it handle edge cases appropriately?
- [ ] Are there any logical errors?
- [ ] Is error handling implemented properly?
- [ ] Does it meet the requirements/acceptance criteria?

### Code Quality

- [ ] Does the code follow project coding standards?
- [ ] Is the code well-organized and easy to understand?
- [ ] Are there any code smells?
  - Duplicate code
  - Overly complex functions
  - Long methods/functions
  - Deep nesting
  - Magic numbers/strings
- [ ] Are functions and variables named appropriately?
- [ ] Are there appropriate comments and documentation?
- [ ] Is the code DRY (Don't Repeat Yourself)?

### Security

- [ ] Is user input properly validated and sanitized?
- [ ] Is output properly escaped?
- [ ] Are capability/permission checks used for user actions?
- [ ] Are there any potential injection vulnerabilities?
  - SQL injection
  - XSS (Cross-Site Scripting)
  - Command injection
- [ ] Are secrets/credentials properly handled?
- [ ] Is authentication/authorization properly implemented?
- [ ] Are there any insecure dependencies?

### Performance

- [ ] Are there any performance bottlenecks?
- [ ] Are database queries optimized?
  - No N+1 queries
  - Proper indexing considered
  - Efficient joins
- [ ] Is caching used appropriately?
- [ ] Are assets properly optimized?
- [ ] Are there any memory leaks?
- [ ] Is async/parallel processing used where beneficial?

### Compatibility

- [ ] Is the code compatible with supported runtime versions?
- [ ] Are there any browser compatibility issues (if web)?
- [ ] Are there any OS compatibility issues?
- [ ] Are there any conflicts with dependencies?
- [ ] Is backward compatibility maintained?

### Testing

- [ ] Are there appropriate unit tests?
- [ ] Are there integration tests for critical paths?
- [ ] Do tests cover edge cases?
- [ ] Are tests well-organized and maintainable?
- [ ] Do all tests pass?
- [ ] Is test coverage adequate?

### Documentation

- [ ] Are public APIs documented?
- [ ] Are complex algorithms explained?
- [ ] Is the README updated if needed?
- [ ] Is the changelog updated?
- [ ] Are breaking changes clearly documented?

### Accessibility (for UI changes)

- [ ] Does the code follow accessibility best practices?
- [ ] Are ARIA attributes used appropriately?
- [ ] Is keyboard navigation supported?
- [ ] Is screen reader support implemented?
- [ ] Is color contrast sufficient?

### Internationalization (if applicable)

- [ ] Are all user-facing strings translatable?
- [ ] Is the correct text domain/locale used?
- [ ] Are translation functions used correctly?
- [ ] Are date/time/number formats localized?

## Code Review Process

### 1. Understand the Context

Before reviewing, understand:

- What problem is the code trying to solve?
- What are the requirements?
- What are the constraints?
- Is there related documentation or issues?

### 2. Review the Code

Review systematically using the checklist above.

### 3. Provide Feedback

When providing feedback:

#### Be Specific and Clear

**Good feedback example:**

> In function `processUserData()` at line 45:
>
> 1. The input validation is missing for the `email` parameter.
>    Consider adding validation like `if (!isValidEmail(email)) { throw new ValidationError('Invalid email format'); }`
>
> 2. The error message should be more descriptive. Instead of `throw new Error('Failed')`,
>    use `throw new Error(\`Failed to process data for user ${userId}: ${reason}\`)`

#### Categorize Feedback

| Category | Description | Action Required |
|----------|-------------|-----------------|
| **Blocker** | Must be fixed before merge | Yes |
| **Major** | Should be fixed, significant issue | Yes |
| **Minor** | Should be fixed, small issue | Preferably |
| **Suggestion** | Optional improvement | No |
| **Question** | Seeking clarification | Response needed |

#### Be Constructive

```markdown
# Poor feedback
This code is bad. Fix it.

# Good feedback
The current implementation could be improved for better maintainability:

Current approach:
- Uses multiple nested callbacks
- Hard to follow the data flow
- Error handling is scattered

Suggested improvement:
- Refactor to use async/await
- Centralize error handling
- Extract helper functions for clarity

Would you like me to provide a specific example?
```

### 4. Follow Up

After code has been updated:

- Review the changes
- Verify issues have been addressed
- Provide additional feedback if necessary
- Approve when ready

## Common Issues to Look For

### General Issues

| Issue | What to Look For |
|-------|------------------|
| Undefined variables | Variables used before declaration |
| Missing error handling | Operations that can fail without try/catch |
| Resource leaks | Unclosed connections, streams, handles |
| Race conditions | Async operations without proper synchronization |
| Hardcoded values | Configuration that should be externalized |

### Language-Specific Issues

#### JavaScript/TypeScript

- Improper async/await usage
- Missing null checks
- Event listener memory leaks
- Improper this binding
- Type safety issues (TypeScript)

#### Python

- Mutable default arguments
- Bare except clauses
- Resource management (use context managers)
- Import organization
- Type hints missing

#### Shell/Bash

- Unquoted variables
- Missing error handling (set -e)
- Hardcoded paths
- Not using shellcheck-compliant patterns
- Missing input validation

#### PHP

- SQL injection vulnerabilities
- Missing input sanitization
- Output not escaped
- Deprecated function usage
- Missing nonces (WordPress)

### Architecture Issues

- Tight coupling between components
- Circular dependencies
- God classes/functions (doing too much)
- Missing abstraction layers
- Inconsistent patterns

## Automated Code Review Tools

Use automated tools to supplement manual review:

### Quality Analysis

```bash
# Run project quality checks
bash ~/git/aidevops/.agent/scripts/quality-check.sh

# Use CodeRabbit for AI-powered review
bash ~/git/aidevops/.agent/scripts/coderabbit-cli.sh review

# Use Codacy for analysis
bash ~/git/aidevops/.agent/scripts/codacy-cli.sh analyze

# Use Qlty for universal checking
bash ~/git/aidevops/.agent/scripts/qlty-cli.sh check
```

### Security Scanning

```bash
# Run Snyk security scan
snyk test

# Check for vulnerable dependencies
npm audit
composer audit
```

### Linting

```bash
# ShellCheck for bash scripts
shellcheck script.sh

# ESLint for JavaScript
npx eslint .

# Pylint for Python
pylint module/
```

## Review Response Template

```markdown
## Code Review: PR #123 - Feature Name

### Summary
Brief overview of what was reviewed and overall assessment.

### Blockers (Must Fix)
1. **Security Issue** - `file.js:45`
   - Description of issue
   - Suggested fix

### Major Issues (Should Fix)
1. **Performance** - `query.js:100`
   - Description
   - Recommendation

### Minor Issues (Nice to Fix)
1. **Style** - `utils.js:20`
   - Description

### Suggestions (Optional)
1. Consider using X pattern for Y

### Questions
1. Why was Z approach chosen over W?

### Positive Notes
- Good test coverage
- Clean separation of concerns
- Well-documented API

### Recommendation
[ ] Approve
[x] Request changes
[ ] Comment only
```
