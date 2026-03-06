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
  webfetch: true
  task: true
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

## External Repo Submissions

When filing issues or PRs on repos you don't maintain, many repos enforce template compliance via bots that auto-close non-conforming submissions. Check their guidelines first.

### Discovering Issue Templates

```bash
# List available issue templates
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/ --jq '.[].name'
# Example output: bug-report.yml  feature-request.yml  config.yml

# Read a specific template (YAML form)
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/bug-report.yml \
  --jq '.content' | base64 -d

# Check for CONTRIBUTING.md
gh api repos/{owner}/{repo}/contents/CONTRIBUTING.md \
  --jq '.content' | base64 -d
```

### Mapping YAML Form Templates to Markdown

GitHub's YAML issue forms (`.yml`) render as structured forms in the web UI. When submitted, they produce markdown with `### Label` headers matching each field's `label:` attribute. To submit a compliant issue via `gh issue create`, replicate this structure.

**Example YAML form fields:**

```yaml
body:
  - type: textarea
    id: description
    attributes:
      label: Describe the bug
  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
  - type: input
    id: version
    attributes:
      label: Version
```

**Corresponding compliant issue body:**

```markdown
### Describe the bug

The application crashes when clicking the save button after editing a profile.

### Steps to reproduce

1. Navigate to Settings > Profile
2. Change the display name
3. Click Save

### Expected behavior

Profile should save and show a success message.

### Actual behavior

Page crashes with a white screen. Console shows: TypeError: Cannot read property 'id' of undefined.

### Version

v2.4.1
```

**Key rules for YAML form compliance:**

- Each `label:` value becomes a `### Label` header — match the text exactly (case-sensitive)
- Every required field must have a non-empty section below its header
- `type: checkboxes` fields render as `- [x]` / `- [ ]` lists under the header
- `type: dropdown` fields render as the selected option text under the header
- `type: input` fields render as plain text under the header
- Fields with `required: true` must not be left blank — compliance bots check this

### Discovering PR Templates

```bash
# Check for PR template
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE.md \
  --jq '.content' | base64 -d

# Some repos use a directory of templates
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE/ \
  --jq '.[].name'
```

### Handling Auto-Close Bots

If a submission is auto-closed by a compliance bot:

1. Read the bot's closing comment — it usually explains what's missing
2. Check the close window (some bots give 2 hours to fix before closing)
3. Resubmit with the correct format rather than editing the closed issue
4. Some bots use AI (e.g., Claude/Sonnet) to verify template compliance — partial matches may not pass

### Quick Checklist

Before submitting to an external repo:

1. Is this repo in `~/.config/aidevops/repos.json`? If yes, skip these checks (it's ours)
2. Does `.github/ISSUE_TEMPLATE/` exist? If yes, use the matching template
3. Does `CONTRIBUTING.md` exist? If yes, follow its guidelines (CLA, branch naming, etc.)
4. For PRs: check if they require signed commits, specific branch targets, or linked issues

## See Also

- `lumen.md` - AI-powered visual diffs, commit message generation, and PR review
- `conflict-resolution.md` - Git conflict resolution strategies
- `worktrunk.md` - Worktree management for parallel work
