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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode GitHub Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Setup**: `opencode github install` (automated) or manual (see [Installation](#installation))
- **Trigger**: `/opencode` or `/oc` in any issue/PR comment
- **App**: <https://github.com/apps/opencode-agent>
- **Docs**: <https://opencode.ai/docs/github/>
- **Requirements**: GitHub App installed, `.github/workflows/opencode.yml`, `ANTHROPIC_API_KEY` secret

| Command | Result |
|---------|--------|
| `/oc explain this` | AI analyzes issue/PR and replies |
| `/oc fix this` | Creates branch, implements fix, opens PR |
| `/oc review this PR` | Reviews code, suggests improvements |
| `/oc add error handling here` | Line-specific fix (in PR Files tab) |

Inline usage: include `/oc` anywhere in a comment (e.g., `This needs validation. /oc add input validation`).

All execution happens on YOUR GitHub Actions runners — code never leaves your environment.

<!-- AI-CONTEXT-END -->

## Installation

### Automated (Recommended)

```bash
opencode github install
```

Walks you through: app install, workflow creation, secrets setup.

### Manual

1. **Install GitHub App**: <https://github.com/apps/opencode-agent> (repo or org)

2. **Create `.github/workflows/opencode.yml`**:

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
        uses: anomalyco/opencode/github@latest
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        with:
          model: anthropic/claude-sonnet-4-6
```

3. **Add secrets** (Settings > Secrets and variables > Actions):
   - `ANTHROPIC_API_KEY` (primary) — also supports `OPENAI_API_KEY`, `GOOGLE_API_KEY`

## Configuration

```yaml
- uses: anomalyco/opencode/github@latest
  with:
    model: anthropic/claude-sonnet-4-6  # Required
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

To use `GITHUB_TOKEN` instead of the app, add `token: ${{ secrets.GITHUB_TOKEN }}` to the `with:` block.

### Permissions

The workflow requires these four permissions (shown in the workflow above):

- `id-token: write` — required for OpenCode
- `contents: write` — committing changes
- `pull-requests: write` — creating/updating PRs
- `issues: write` — commenting on issues

## Check Setup Status

```bash
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check
```

Checks: git remote type, GitHub App installation, workflow file presence, required secrets.

## Security

- **Runs on YOUR runners** — code never leaves your GitHub Actions environment
- **Secrets stay secret** — API keys stored in GitHub Secrets
- **Scoped permissions** — only accesses what the workflow allows
- **Audit trail** — all actions visible in Actions tab

### Hardening (Recommended for Production)

The basic workflow allows ANY user to trigger AI commands. Restrict to trusted users:

```yaml
# Replace the 'if' condition in the workflow job
if: |
  (contains(github.event.comment.body, '/oc') ||
   contains(github.event.comment.body, '/opencode')) &&
  (github.event.comment.author_association == 'OWNER' ||
   github.event.comment.author_association == 'MEMBER' ||
   github.event.comment.author_association == 'COLLABORATOR')
```

**Full security implementation** (trusted user validation, `ai-approved` label gates, prompt injection detection, audit logging): see `git/opencode-github-security.md`.

Quick setup with max security:

```bash
cp .github/workflows/opencode-agent.yml .github/workflows/opencode.yml
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent"
gh label create "security-review" --color "D93F0B" --description "Requires security review"
```

## Integration with aidevops

OpenCode respects aidevops branch naming (`feature/`, `bugfix/`, etc.) and triggers existing CI workflows. Configure the prompt for aidevops conventions:

```yaml
prompt: |
  Follow these guidelines:
  - Use conventional commit messages
  - Create feature/ or bugfix/ branches
  - Include ## Summary section in PR description
  - Run quality checks before committing
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| OpenCode not responding | Verify: workflow file exists, Actions tab shows run, `ANTHROPIC_API_KEY` secret set |
| Permission denied | Check workflow `permissions:` block matches [Permissions](#permissions) section |
| App not installed | Install at <https://github.com/apps/opencode-agent>, or use `token: ${{ secrets.GITHUB_TOKEN }}` (no app needed) |

## Related

- `git/opencode-github-security.md` — full security hardening guide
- `git/opencode-gitlab.md` — GitLab integration
- `git/github-cli.md` — GitHub CLI
- `git/github-actions.md` — GitHub Actions
- `workflows/git-workflow.md` — git workflow
