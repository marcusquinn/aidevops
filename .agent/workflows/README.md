# Development Workflows

This directory contains workflow guides for AI assistants working on any codebase - whether this aidevops repository, WordPress projects, or any other development work.

## Purpose

These workflows provide **universal best practices** that apply to:

- Working on this aidevops repository
- Working on any other codebase using this framework
- WordPress plugin/theme development
- General software development projects

## Workflow Files

### Git & Version Control

| File | Description |
|------|-------------|
| **git-workflow.md** | Comprehensive git practices, branching strategies, and collaboration |
| **release-process.md** | Complete release workflow with semantic versioning |

### Development Lifecycle

| File | Description |
|------|-------------|
| **feature-development.md** | Feature development from branch creation to merge |
| **bug-fixing.md** | Bug fix workflow with hotfix procedures |

### Code Quality

| File | Description |
|------|-------------|
| **code-review.md** | Universal code review checklist |
| **error-checking-feedback-loops.md** | CI/CD monitoring and automated resolution |

### Context Management

| File | Description |
|------|-------------|
| **multi-repo-workspace.md** | Working safely across multiple repositories |

### Platform-Specific

| File | Description |
|------|-------------|
| **wordpress-local-testing.md** | WordPress Playground, LocalWP, wp-env testing |

## Quick Reference

### Starting New Work

1. Review **git-workflow.md** for branching strategy
2. Use **feature-development.md** or **bug-fixing.md** as appropriate
3. Follow **code-review.md** before requesting review

### Releasing

1. Follow **release-process.md** step-by-step
2. Monitor CI/CD using **error-checking-feedback-loops.md**

### Multi-Repo Work

1. Always check **multi-repo-workspace.md** before starting
2. Verify repository context before making changes

### WordPress Development

1. Use **wordpress-local-testing.md** for environment setup
2. Follow platform-specific guidance from `.agent/*.md` files

## Usage

AI assistants should reference these workflows when:

1. Starting new development work
2. Preparing code for review or release
3. Troubleshooting CI/CD failures
4. Working in multi-repository environments
5. Needing structured approaches to common tasks

## Relationship to Other `.agent/` Content

| Directory/Files | Purpose |
|-----------------|---------|
| `.agent/workflows/` | **How to work** - Development processes and methodologies |
| `.agent/scripts/` | **Tools to use** - Automation and helper scripts |
| `.agent/*.md` (root) | **What services exist** - Service documentation and integrations |
| `.agent/memory/` | **What to remember** - Persistent context and preference templates |

## File Naming Convention

- Use lowercase filenames
- Use hyphens to separate words
- Be descriptive but concise
- Example: `feature-development.md`, `code-review.md`

## Contributing

When adding new workflows:

1. Use lowercase filenames with hyphens
2. Include practical examples and commands
3. Make workflows generic enough for any codebase
4. Add language/platform-specific sections where needed
5. Reference specific tools/services from `.agent/*.md` files
6. Update this README with the new file

## Workflow Template

When creating a new workflow file:

```markdown
# [Workflow Name]

Brief description of what this workflow covers.

## Overview

When to use this workflow and prerequisites.

## Steps

### 1. First Step

Details with code examples:

\`\`\`bash
# Command example
command --flag
\`\`\`

### 2. Second Step

Continue with structured steps...

## Checklist

- [ ] Item 1
- [ ] Item 2

## Troubleshooting

Common issues and solutions.

## Related Workflows

- Link to related workflows
```
