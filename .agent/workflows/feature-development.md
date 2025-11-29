# Feature Development Guide for AI Assistants

This document provides guidance for developing new features in any codebase.

## Feature Development Workflow

### 1. Create a Feature Branch

Always start from the latest main branch (mandatory):

```bash
git checkout main
git pull origin main
git checkout -b feature/descriptive-name
```

Use descriptive names. Include issue numbers when available:

```bash
git checkout -b feature/123-user-dashboard
git checkout -b feature/api-rate-limiting
git checkout -b feature/export-functionality
```

### 2. Understand Requirements

Before implementing:

| Question | Purpose |
|----------|---------|
| What problem does this solve? | Validates necessity |
| Who will use this feature? | Defines UX approach |
| How should it behave? | Defines acceptance criteria |
| What are the edge cases? | Prevents bugs |
| What are the dependencies? | Plans integration |

### 3. Implement the Feature

When implementing:

- Follow project coding standards
- Ensure all strings are translatable (if applicable)
- Add appropriate comments and documentation
- Consider performance implications
- Maintain backward compatibility
- Review existing code for patterns to follow

### 4. Time-Efficient Development

#### Development Branches (Without Version Numbers)

During initial development:

```bash
# Create descriptive branch
git checkout -b feature/user-authentication

# Work on implementation
# DON'T update version numbers yet
# Focus on functionality

# Commit frequently
git add .
git commit -m "Add: User authentication logic"
```

#### Testing Iterations

```bash
# Local testing - use current version
npm test
composer test

# Build without version changes
npm run build
```

#### Version Branch (Only When Ready)

Only create version branches when feature is confirmed working:

```bash
# Determine version increment (usually MINOR for features)
git checkout -b v{MAJOR}.{MINOR+1}.0

# NOW update version numbers
# Commit version updates
git commit -m "Version {VERSION} - Add user authentication"
```

### 5. Update Documentation

Update all relevant documentation:

**CHANGELOG.md:**

```markdown
## [Unreleased]
### Added
- New feature: Description of what was added (#123)
```

**README.md / readme.txt:**

- Update feature list
- Add usage instructions
- Update screenshots if UI changed

**Code Comments:**

- Add docblocks to new functions/methods
- Document complex logic
- Add usage examples

### 6. Testing

Test the feature thoroughly:

- [ ] Feature works as specified
- [ ] Edge cases handled
- [ ] Error handling works
- [ ] Performance is acceptable
- [ ] No regression in existing functionality
- [ ] Works in supported environments
- [ ] Accessibility requirements met (if UI)

```bash
# Run test suite
npm test
composer test

# Run quality checks
bash ~/git/aidevops/.agent/scripts/quality-check.sh

# Run specific tests
npm run test:feature
```

### 7. Commit Changes

Make atomic, well-documented commits:

```bash
git add .
git commit -m "Add: Feature description

- Implemented X functionality
- Added Y component
- Integrated with Z system

Closes #123"
```

### 8. Prepare for Release

When feature is ready:

```bash
# Create version branch (MINOR increment for features)
git checkout -b v{MAJOR}.{MINOR+1}.0

# Update version numbers in all files
# - Main application file
# - package.json / composer.json
# - CHANGELOG.md
# - README files
# - Localization files

git add .
git commit -m "Version {VERSION} - Feature name"

# Tag as stable when confirmed
git tag -a v{VERSION}-stable -m "Stable version {VERSION}"
```

## Code Standards Reminders

### General Best Practices

```javascript
// Use descriptive names
const userAuthenticationService = new AuthService();  // GOOD
const uas = new AuthService();  // BAD

// Handle errors explicitly
try {
  await riskyOperation();
} catch (error) {
  logger.error('Operation failed:', error);
  throw new OperationError('Descriptive message', { cause: error });
}

// Document complex logic
/**
 * Calculates user permission level based on role hierarchy.
 * 
 * @param {User} user - The user to check
 * @param {Resource} resource - The resource being accessed
 * @returns {PermissionLevel} The calculated permission level
 */
function calculatePermissions(user, resource) {
  // Implementation
}
```

### Security Best Practices

- Validate and sanitize all input
- Escape all output
- Use parameterized queries
- Implement proper authentication/authorization
- Follow principle of least privilege

### Performance Considerations

- Avoid N+1 queries
- Use caching where appropriate
- Lazy load when possible
- Profile before optimizing

## Working in Multi-Repository Workspaces

When developing features in a workspace with multiple repositories:

### 1. Verify Repository Context

```bash
# Confirm you're in the right repository
pwd
git remote -v
```

### 2. Feature Verification

Before implementing, verify it doesn't already exist:

```bash
# Search codebase for similar functionality
grep -r "feature-keyword" .
```

### 3. Repository-Specific Implementation

- Implement features appropriate for this specific project
- Maintain consistency with the project's architecture
- Don't copy code from other repositories without adaptation

### 4. Cross-Repository Inspiration

If implementing a feature inspired by another repository:

- Explicitly note it's a new feature
- Adapt to fit current project's architecture
- Document the inspiration source in comments

## Feature Types and Guidelines

### API Features

- Follow REST conventions (or project's API style)
- Version the API appropriately
- Document all endpoints
- Include request/response examples
- Handle errors consistently

### UI Features

- Follow existing design patterns
- Ensure accessibility compliance
- Add appropriate help text
- Test responsive behavior
- Consider internationalization

### Backend Features

- Use existing patterns for consistency
- Consider scalability
- Add monitoring/logging
- Document configuration options
- Plan for failure scenarios

### Integration Features

- Make integrations optional when possible
- Check if dependencies are available
- Provide fallback behavior
- Document integration requirements

## Feature Development Checklist

Before marking feature as complete:

- [ ] Requirements fully implemented
- [ ] Edge cases handled
- [ ] Error handling complete
- [ ] Tests written and passing
- [ ] Documentation updated
- [ ] Code review ready
- [ ] Quality checks pass
- [ ] No regression in existing features
- [ ] Performance acceptable
- [ ] Security considerations addressed
- [ ] Accessibility requirements met (if UI)
- [ ] Changelog updated
