---
description: OpenCode GitHub App integration for AI-powered issue/PR automation
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

# OpenCode GitHub Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Setup**: `opencode github install` (automated)
- **Trigger**: `/opencode` or `/oc` in any issue/PR comment
- **App**: https://github.com/apps/opencode-agent
- **Docs**: https://opencode.ai/docs/github/

**What It Does**:

| Command | Result |
|---------|--------|
| `/oc explain this` | AI analyzes issue/PR and replies |
| `/oc fix this` | Creates branch, implements fix, opens PR |
| `/oc review this PR` | Reviews code, suggests improvements |
| `/oc add error handling here` | Line-specific fix (in Files tab) |

**Requirements**:
- GitHub App installed on repo/org
- Workflow file: `.github/workflows/opencode.yml`
- Secret: `ANTHROPIC_API_KEY` (or other AI provider)

<!-- AI-CONTEXT-END -->

## Overview

OpenCode's GitHub integration enables AI-powered automation directly from GitHub issues and pull requests. When you comment `/oc fix this` on an issue, OpenCode:

1. Analyzes the issue context
2. Creates a new branch
3. Implements the fix
4. Opens a pull request with the changes

All execution happens securely on YOUR GitHub Actions runners.

## Installation

### Automated Setup (Recommended)

```bash
opencode github install
```

This walks you through:
1. Installing the GitHub App
2. Creating the workflow file
3. Setting up secrets

### Manual Setup

#### 1. Install GitHub App

Visit: https://github.com/apps/opencode-agent

Install for your repository or organization.

#### 2. Create Workflow File

Create `.github/workflows/opencode.yml`:

```yaml
name: opencode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  opencode:
    if: |
      contains(github.event.comment.body, '/oc') ||
      contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
      pull-requests: write
      issues: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Run OpenCode
        uses: sst/opencode/github@latest
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        with:
          model: anthropic/claude-sonnet-4-20250514
```

#### 3. Add Secrets

Go to: Repository Settings → Secrets and variables → Actions

Add your AI provider API key:
- **Name**: `ANTHROPIC_API_KEY`
- **Value**: Your Anthropic API key

Other supported providers:
- `OPENAI_API_KEY`
- `GOOGLE_API_KEY`

## Usage

### In Issues

Comment on any issue:

```text
/opencode explain this issue
```

OpenCode reads the issue title, description, and comments, then replies with an explanation.

```text
/oc fix this
```

OpenCode creates a branch, implements a fix, and opens a PR.

### In Pull Requests

Comment on a PR:

```text
/opencode review this PR
```

OpenCode analyzes the changes and provides feedback.

### Line-Specific Reviews

In the PR "Files" tab, comment on a specific line:

```text
/oc add error handling here
```

OpenCode sees:
- The exact file
- The specific line(s)
- Surrounding diff context

And makes targeted changes.

### Inline Commands

You can include `/oc` anywhere in your comment:

```text
This function needs better validation. /oc add input validation
```

## Configuration Options

### Workflow Configuration

```yaml
- uses: sst/opencode/github@latest
  with:
    model: anthropic/claude-sonnet-4-20250514  # Required
    agent: build                                # Optional: agent to use
    share: true                                 # Optional: share session (default: true for public repos)
    prompt: |                                   # Optional: custom prompt
      Review this PR focusing on:
      - Security issues
      - Performance problems
    token: ${{ secrets.CUSTOM_TOKEN }}         # Optional: custom GitHub token
```

### Token Options

| Token Type | Description | Use Case |
|------------|-------------|----------|
| OpenCode App Token | Default, commits as "opencode-agent" | Standard usage |
| `GITHUB_TOKEN` | Built-in runner token | No app installation needed |
| Personal Access Token | Your identity | Commits appear as you |

To use `GITHUB_TOKEN` instead of the app:

```yaml
- uses: sst/opencode/github@latest
  with:
    model: anthropic/claude-sonnet-4-20250514
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Permissions

The workflow requires these permissions:

```yaml
permissions:
  id-token: write      # Required for OpenCode
  contents: write      # For committing changes
  pull-requests: write # For creating/updating PRs
  issues: write        # For commenting on issues
```

## Check Setup Status

Use the helper script to verify your setup:

```bash
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check
```

This checks:
- Git remote type (GitHub/GitLab/Gitea)
- GitHub App installation status
- Workflow file presence
- Required secrets

## Troubleshooting

### OpenCode Not Responding

1. **Check workflow exists**: `.github/workflows/opencode.yml`
2. **Check workflow ran**: Repository → Actions tab
3. **Check secrets**: Settings → Secrets → `ANTHROPIC_API_KEY`

### Permission Denied

Ensure workflow has correct permissions:

```yaml
permissions:
  id-token: write
  contents: write
  pull-requests: write
  issues: write
```

### App Not Installed

Visit https://github.com/apps/opencode-agent and install for your repo.

Or use `GITHUB_TOKEN` instead (no app needed):

```yaml
token: ${{ secrets.GITHUB_TOKEN }}
```

## Security

- **Runs on YOUR runners**: Code never leaves your GitHub Actions environment
- **Secrets stay secret**: API keys stored in GitHub Secrets
- **Scoped permissions**: Only accesses what the workflow allows
- **Audit trail**: All actions visible in Actions tab

### Security Hardening (Recommended)

The basic workflow above allows ANY user to trigger AI commands. For production use, implement security hardening:

```yaml
# Add to your workflow job
if: |
  (contains(github.event.comment.body, '/oc') ||
   contains(github.event.comment.body, '/opencode')) &&
  (github.event.comment.author_association == 'OWNER' ||
   github.event.comment.author_association == 'MEMBER' ||
   github.event.comment.author_association == 'COLLABORATOR')
```

**Full security implementation**: See `git/opencode-github-security.md` for:
- Trusted user validation
- `ai-approved` label requirement for issues
- Prompt injection pattern detection
- Audit logging
- Security-focused system prompts

**Quick setup with max security**:

```bash
# Copy the secure workflow
cp .github/workflows/opencode-agent.yml .github/workflows/opencode.yml

# Create required labels
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent"
gh label create "security-review" --color "D93F0B" --description "Requires security review"
```

## Integration with aidevops

When using aidevops workflows:

1. **Branch creation**: OpenCode respects aidevops branch naming (`feature/`, `bugfix/`, etc.)
2. **PR format**: Configure prompt to follow aidevops PR template
3. **Quality checks**: OpenCode PRs trigger your existing CI workflows

Example custom prompt for aidevops style:

```yaml
prompt: |
  Follow these guidelines:
  - Use conventional commit messages
  - Create feature/ or bugfix/ branches
  - Include ## Summary section in PR description
  - Run quality checks before committing
```

## Related

- **Security hardening**: `git/opencode-github-security.md` - Full security guide
- **GitLab integration**: `git/opencode-gitlab.md`
- **GitHub CLI**: `git/github-cli.md`
- **GitHub Actions**: `git/github-actions.md`
- **Git workflow**: `workflows/git-workflow.md`
