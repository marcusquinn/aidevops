---
description: GitHub CLI (gh) for repos, PRs, issues, and actions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  list: true
  webfetch: true
---

# GitHub CLI Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI Tool**: `gh` (GitHub CLI) - the official GitHub CLI
- **Install**: `brew install gh` (macOS) | `apt install gh` (Ubuntu)
- **Auth**: `gh auth login` (stores token in keyring)
- **Status**: `gh auth status`
- **Docs**: https://cli.github.com/manual

**Common Commands**:

```bash
gh repo list                    # List your repos
gh repo create NAME             # Create repo
gh issue list                   # List issues
gh issue create                 # Create issue
gh pr list                      # List PRs
gh pr create                    # Create PR
gh pr merge                     # Merge PR
gh release create TAG           # Create release
gh release list                 # List releases
```

**Multi-Account**: `gh auth login` supports multiple accounts via keyring
<!-- AI-CONTEXT-END -->

## Overview

The `gh` CLI is the official GitHub command-line tool. It handles authentication securely via your system keyring and provides comprehensive access to GitHub features. **Use `gh` directly rather than wrapper scripts.**

## Installation

```bash
# macOS
brew install gh

# Ubuntu/Debian
sudo apt install gh

# Other platforms
# See: https://cli.github.com/manual/installation
```

## Authentication

```bash
# Login (interactive - stores token in keyring)
gh auth login

# Check auth status
gh auth status

# Get current token (for scripts that need GITHUB_TOKEN)
gh auth token
```

Authentication is stored securely in your system keyring. No need for `GITHUB_TOKEN` environment variable for normal `gh` operations.

## Repository Management

```bash
# List your repositories
gh repo list

# Create new repository
gh repo create my-repo --public --description "My project"

# Clone a repository
gh repo clone owner/repo

# View repository info
gh repo view owner/repo

# Fork a repository
gh repo fork owner/repo
```

## Issue Management

```bash
# List issues
gh issue list
gh issue list --state open --label bug

# Create issue
gh issue create --title "Bug report" --body "Description"

# View issue
gh issue view 123

# Close issue
gh issue close 123
```

## Pull Request Management

```bash
# List PRs
gh pr list
gh pr list --state open

# Create PR
gh pr create --title "Feature X" --body "Description"
gh pr create --fill  # Auto-fill from commits

# View PR
gh pr view 123

# Merge PR
gh pr merge 123 --squash
gh pr merge 123 --merge
gh pr merge 123 --rebase
```

## Release Management

```bash
# Create release with auto-generated notes
gh release create v1.2.3 --generate-notes

# Create release with custom notes
gh release create v1.2.3 --notes "Release notes here"

# Create draft release
gh release create v1.2.3 --draft --generate-notes

# List releases
gh release list

# View latest release
gh release view

# Download release assets
gh release download v1.2.3
```

## Workflow/Actions

```bash
# List workflow runs
gh run list

# View run details
gh run view 123456

# Watch a running workflow
gh run watch

# Re-run failed jobs
gh run rerun 123456 --failed
```

## API Access

```bash
# Make API calls directly
gh api repos/owner/repo
gh api repos/owner/repo/issues

# Create via API
gh api repos/owner/repo/issues -f title="Bug" -f body="Details"
```

## Multi-Account Support

The `gh` CLI supports multiple accounts:

```bash
# Login to additional account
gh auth login

# Switch between accounts
gh auth switch

# List authenticated accounts
gh auth status
```

## Environment Variables

For scripts that need a token:

```bash
# Get token from gh auth
export GITHUB_TOKEN=$(gh auth token)

# Or use GH_TOKEN (preferred by gh)
export GH_TOKEN=$(gh auth token)
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "not logged in" | Run `gh auth login` |
| "token expired" | Run `gh auth refresh` |
| Wrong account | Run `gh auth switch` |
| Need token for script | Use `$(gh auth token)` |

## Best Practices

1. **Use `gh` directly** - No wrapper scripts needed
2. **Use keyring auth** - More secure than env vars
3. **Use `--generate-notes`** - Auto-generate release notes from commits/PRs
4. **Use `gh api`** - For advanced GitHub API access
5. **Use `gh pr create --fill`** - Auto-fill PR details from commits
