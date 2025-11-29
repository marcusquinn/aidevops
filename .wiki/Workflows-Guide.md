# Workflows Guide

The `.agent/workflows/` directory contains process guides for common development tasks. These workflows help AI assistants (and humans) follow consistent, high-quality practices.

## Available Workflows

### Git & Version Control

| Workflow | When to Use |
|----------|-------------|
| **[git-workflow.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/git-workflow.md)** | Branching strategies, commit conventions, collaboration |
| **[release-process.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/release-process.md)** | Version bumps, tagging, GitHub releases |

### Development Lifecycle

| Workflow | When to Use |
|----------|-------------|
| **[feature-development.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/feature-development.md)** | Building new features from start to merge |
| **[bug-fixing.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/bug-fixing.md)** | Fixing bugs, including hotfix procedures |

### Code Quality

| Workflow | When to Use |
|----------|-------------|
| **[code-review.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/code-review.md)** | Code review checklist before merging |
| **[error-checking-feedback-loops.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/error-checking-feedback-loops.md)** | Monitoring CI/CD, fixing failures |

### Context & Safety

| Workflow | When to Use |
|----------|-------------|
| **[multi-repo-workspace.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/multi-repo-workspace.md)** | Working across multiple repositories safely |

### Platform-Specific

| Workflow | When to Use |
|----------|-------------|
| **[wordpress-local-testing.md](https://github.com/marcusquinn/aidevops/blob/main/.agent/workflows/wordpress-local-testing.md)** | WordPress Playground, LocalWP, wp-env |

## Workflow Quick Reference

### Starting New Work

```
1. Check git-workflow.md for branching strategy
2. Use feature-development.md OR bug-fixing.md
3. Follow code-review.md before PR
```

### Releasing a Version

```
1. Follow release-process.md step-by-step
2. Use error-checking-feedback-loops.md for CI monitoring
3. Create GitHub release with changelog
```

### Working in Multiple Repos

```
1. Read multi-repo-workspace.md FIRST
2. Always verify which repo you're in
3. Don't assume features from one repo exist in another
```

## How AI Uses Workflows

### Example: Feature Development

When you say "Add a new feature for user authentication":

1. AI reads `feature-development.md`
2. Creates feature branch following naming convention
3. Implements feature with proper structure
4. Follows code review checklist
5. Prepares PR with appropriate description

### Example: Bug Fix

When you say "Fix the login timeout issue":

1. AI reads `bug-fixing.md`
2. Determines if regular fix or hotfix needed
3. Creates appropriate branch
4. Fixes bug with proper testing
5. Documents the fix in commit message

### Example: Release

When you say "Release version 2.1.0":

1. AI reads `release-process.md`
2. Updates version in relevant files
3. Updates CHANGELOG.md
4. Creates annotated tag
5. Pushes and creates GitHub release

## Workflow Principles

### Universal Application

These workflows work for:
- This aidevops repository
- Any other codebase
- WordPress projects
- General software development

### AI-Friendly Structure

Each workflow includes:
- Clear step-by-step instructions
- Code examples and commands
- Checklists for verification
- Troubleshooting sections

### Consistency Over Flexibility

Following consistent workflows:
- Reduces errors
- Improves collaboration
- Creates audit trails
- Enables automation

## Quick Scripts

### Check Quality Status

```bash
# Get all quality feedback for current PR
bash ~/git/aidevops/.agent/scripts/quality-feedback-helper.sh status --pr NUMBER
```

### Run Code Review Check

```bash
# Run automated quality checks
bash ~/git/aidevops/.agent/scripts/quality-check.sh
```

### Monitor CI/CD

```bash
# Watch for check completion
bash ~/git/aidevops/.agent/scripts/quality-feedback-helper.sh watch --pr NUMBER
```

## Related Pages

- **[The .agent Directory](The-Agent-Directory)** - Directory structure
- **[Understanding AGENTS.md](Understanding-AGENTS-md)** - AI instruction file
- **[Getting Started](Getting-Started)** - Installation and setup
