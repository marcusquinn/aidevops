# Multi-Repository Workspace Guidelines

This document provides guidelines for AI assistants working in workspaces that contain multiple repository folders.

## Understanding Multi-Repository Workspaces

Modern development environments often include multiple repository folders in a single workspace. This allows working on related projects simultaneously or referencing code from one project while working on another.

### Common Workspace Configurations

1. **Microservices Architecture**: Multiple service repositories in one workspace
2. **Monorepo with Dependencies**: Main repo with shared library repos
3. **Plugin/Extension Ecosystems**: Core project with plugin repositories
4. **Reference Repositories**: Including repos purely for reference or inspiration
5. **Multi-Platform Projects**: Web, mobile, and API repos together

## Potential Issues in Multi-Repository Workspaces

### 1. Feature Hallucination

The most critical issue - assuming features from one repository should exist in another, or documenting non-existent features based on code seen in other repositories.

**Example**: Seeing authentication code in Repo A and documenting it as existing in Repo B.

### 2. Cross-Repository Code References

Referencing or suggesting code patterns from one repository when working on another leads to:
- Inconsistent coding styles
- Mismatched dependencies
- Incorrect API assumptions

### 3. Documentation Confusion

Creating documentation that includes features or functionality from other repositories in the workspace.

### 4. Scope Creep

Suggesting changes or improvements based on other repositories, leading to scope creep and feature bloat.

### 5. Dependency Confusion

Assuming shared dependencies exist across repositories when they don't.

## Best Practices for AI Assistants

### 1. Repository Verification

**ALWAYS** verify which repository you're currently working in before:

- Making code suggestions
- Creating or updating documentation
- Discussing features or functionality
- Implementing new features
- Running commands

```bash
# Verify current repository
pwd
git remote -v
git rev-parse --show-toplevel
```

### 2. Explicit Code Search Scoping

When searching for code or functionality:

- Explicitly limit searches to the current repository
- Use repository-specific paths in search queries
- Verify search results are from the current repository before using them
- Check file paths in search results

### 3. Feature Verification Process

Before documenting or implementing a feature:

1. **Check the codebase**: Search for relevant code in the current repository only
2. **Verify functionality**: Look for actual implementation, not just references or comments
3. **Check documentation**: Review existing documentation to understand intended functionality
4. **Ask for clarification**: If uncertain, ask the developer to confirm the feature's existence or scope

### 4. Documentation Guidelines

When creating or updating documentation:

1. **Repository-specific content**: Only document features that exist in the current repository
2. **Verify before documenting**: Check the codebase to confirm features actually exist
3. **Clear boundaries**: Make it clear which repository the documentation applies to
4. **Accurate feature descriptions**: Describe features as implemented, not as they might be in other repos

### 5. Cross-Repository Inspiration

When implementing features inspired by other repositories:

1. **Explicit attribution**: Clearly state the feature is inspired by another repository
2. **New implementation**: Treat it as a new feature being added, not existing
3. **Repository-appropriate adaptation**: Adapt to fit the current repository's architecture
4. **Developer confirmation**: Confirm with the developer that adding the feature is appropriate

## Repository Context Verification Checklist

Before making significant changes or recommendations:

- [ ] Verified current working directory/repository
- [ ] Confirmed repository name and purpose
- [ ] Checked that code searches are limited to current repository
- [ ] Verified features exist in current repository before documenting them
- [ ] Ensured documentation reflects only current repository's functionality
- [ ] Confirmed any cross-repository inspiration is clearly marked as new functionality
- [ ] Checked dependencies are appropriate for current repository

## Example Verification Workflow

### 1. Check Current Repository

```bash
# Get repository root
git rev-parse --show-toplevel

# Get remote information
git remote -v

# Check branch context
git branch --show-current
```

### 2. Verify Feature Existence

```bash
# Search within current repo only
grep -r "featureName" --include="*.js" .

# Use git grep (respects .gitignore)
git grep "featureName"

# Check specific files
ls -la src/features/
```

### 3. Document with Clear Repository Context

```markdown
# [Repository Name] - Feature Documentation

This documentation applies to the [repository-name] repository.

## Features
- Feature A (verified in src/features/a.js)
- Feature B (verified in src/features/b.js)
```

### 4. When Suggesting New Features

```markdown
## Proposed Feature: [Name]

**Note**: This feature is inspired by [other-repo] but does not currently exist
in this repository.

**Rationale for adding**: [Explain why it's appropriate]

**Implementation approach**: [Repository-specific approach]
```

## Handling Repository Switching

When the developer switches between repositories in the workspace:

1. **Acknowledge the switch**: Confirm the new repository context
2. **Reset context**: Don't carry over assumptions from the previous repository
3. **Verify new environment**: Check the structure and features of the new repository
4. **Update documentation references**: Reference documentation specific to the new repository
5. **Check for differences**: Note any differences in tooling, dependencies, or conventions

## Common Multi-Repo Patterns

### Monorepo with Packages

```text
workspace/
├── packages/
│   ├── core/           # Core library
│   ├── ui/             # UI components
│   └── utils/          # Shared utilities
├── apps/
│   ├── web/            # Web application
│   └── mobile/         # Mobile application
└── package.json        # Root workspace config
```

**Key considerations**:

- Shared dependencies are managed at root level
- Package-specific dependencies in each package
- Cross-package imports use workspace protocols

### Multiple Separate Repos

```text
workspace/
├── api-service/        # Backend API
├── web-client/         # Frontend application
├── shared-types/       # TypeScript definitions
└── infrastructure/     # IaC configurations
```

**Key considerations**:

- Each repo has its own dependencies
- No implicit sharing between repos
- Must explicitly publish/consume shared code

## Tools for Multi-Repo Management

### Git Worktrees

```bash
# Create a worktree for a branch
git worktree add ../feature-branch feature-branch

# List worktrees
git worktree list

# Remove a worktree
git worktree remove ../feature-branch
```

### Repository-Specific Configuration

Each repository should have:
- `.editorconfig` - Editor settings
- `.gitignore` - Ignore patterns
- `package.json` or equivalent - Dependencies
- `README.md` - Repository documentation
- `.github/` or `.gitlab/` - CI/CD configuration

## Warning Signs of Context Confusion

Watch for these indicators that context may be mixed:

1. **Import paths don't exist**: Suggesting imports from paths not in current repo
2. **API mismatches**: Referencing APIs that exist in a different repo
3. **Configuration confusion**: Suggesting config that belongs to another repo
4. **Test file mismatches**: Running tests that don't exist in current repo
5. **Documentation inconsistencies**: Docs mention features from other repos

## Recovery from Context Confusion

If you realize context has been mixed:

1. **Stop immediately**: Don't continue with potentially incorrect assumptions
2. **Verify current repository**: Re-confirm which repo you're in
3. **Review recent actions**: Check if any incorrect changes were made
4. **Correct documentation**: Update any documentation that mixed contexts
5. **Communicate clearly**: Inform the developer about the confusion and corrections
