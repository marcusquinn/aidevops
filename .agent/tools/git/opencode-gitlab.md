---
description: OpenCode GitLab integration for AI-powered issue/MR automation
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

# OpenCode GitLab Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Trigger**: `@opencode` in any issue/MR comment
- **Runs on**: Your GitLab CI runners (secure)
- **Docs**: https://opencode.ai/docs/gitlab/

**What It Does**:

| Command | Result |
|---------|--------|
| `@opencode explain this` | AI analyzes issue/MR and replies |
| `@opencode fix this` | Creates branch, implements fix, opens MR |
| `@opencode review this MR` | Reviews code, suggests improvements |

**Requirements**:
- GitLab CI/CD pipeline configured
- CI/CD Variables: `ANTHROPIC_API_KEY`, `GITLAB_TOKEN_OPENCODE`, `GITLAB_HOST`
- Service account for git operations

<!-- AI-CONTEXT-END -->

## Overview

OpenCode's GitLab integration enables AI-powered automation directly from GitLab issues and merge requests. When you comment `@opencode fix this` on an issue, OpenCode:

1. Analyzes the issue context
2. Creates a new branch
3. Implements the fix
4. Opens a merge request with the changes

All execution happens securely on YOUR GitLab CI runners.

## Installation

### Prerequisites

1. GitLab repository with CI/CD enabled
2. AI provider API key (Anthropic, OpenAI, etc.)
3. GitLab access token for the service account
4. `glab` CLI available in your CI image

### Step 1: Create Service Account

Create a GitLab user or use a project access token for OpenCode operations.

Required scopes:
- `api` - Full API access
- `read_repository` - Read repository
- `write_repository` - Write repository

### Step 2: Configure CI/CD Variables

Go to: Settings → CI/CD → Variables

Add these variables:

| Variable | Value | Protected | Masked |
|----------|-------|-----------|--------|
| `ANTHROPIC_API_KEY` | Your API key | Yes | Yes |
| `GITLAB_TOKEN_OPENCODE` | Service account token | Yes | Yes |
| `GITLAB_HOST` | `gitlab.com` or your instance | No | No |

### Step 3: Create CI/CD Pipeline

Create `.gitlab-ci.yml` or add to existing:

```yaml
stages:
  - opencode

opencode:
  stage: opencode
  image: node:22-slim
  rules:
    # Trigger on issue/MR comments containing @opencode
    - if: '$CI_PIPELINE_SOURCE == "trigger"'
      when: always
  before_script:
    - npm install --global opencode-ai
    - apt-get update && apt-get install -y git
    # Install glab CLI
    - |
      curl -sL https://github.com/profclems/glab/releases/latest/download/glab_Linux_x86_64.tar.gz | tar xz
      mv glab /usr/local/bin/
    # Configure git
    - git config --global user.email "opencode@gitlab.com"
    - git config --global user.name "OpenCode"
    # Setup OpenCode auth
    - mkdir -p ~/.local/share/opencode
    - |
      cat > ~/.local/share/opencode/auth.json << EOF
      { "anthropic": { "apiKey": "$ANTHROPIC_API_KEY" } }
      EOF
  script:
    # Run OpenCode with the trigger context
    - opencode run "$AI_FLOW_INPUT"
    # Commit and push any changes
    - |
      if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -m "OpenCode changes"
        git push origin HEAD:"$CI_WORKLOAD_REF"
      fi
  variables:
    GIT_STRATEGY: clone
    GIT_DEPTH: 1
```

### Step 4: Configure Webhook (Optional)

For automatic triggering on comments, configure a webhook:

1. Go to: Settings → Webhooks
2. URL: Your pipeline trigger URL
3. Trigger: Note events (issues and MRs)

## Usage

### In Issues

Comment on any issue:

```text
@opencode explain this issue
```

OpenCode reads the issue and replies with an explanation.

```text
@opencode fix this
```

OpenCode creates a branch, implements a fix, and opens an MR.

### In Merge Requests

Comment on an MR:

```text
@opencode review this merge request
```

OpenCode analyzes the changes and provides feedback.

## Configuration

### Using Different AI Providers

Update the auth.json creation in your pipeline:

```yaml
# For OpenAI
- |
  cat > ~/.local/share/opencode/auth.json << EOF
  { "openai": { "apiKey": "$OPENAI_API_KEY" } }
  EOF

# For multiple providers
- |
  cat > ~/.local/share/opencode/auth.json << EOF
  {
    "anthropic": { "apiKey": "$ANTHROPIC_API_KEY" },
    "openai": { "apiKey": "$OPENAI_API_KEY" }
  }
  EOF
```

### Custom Model

Specify model in the opencode run command:

```yaml
script:
  - opencode run --model anthropic/claude-sonnet-4-20250514 "$AI_FLOW_INPUT"
```

### Self-Hosted GitLab

Set `GITLAB_HOST` to your instance URL:

```yaml
variables:
  GITLAB_HOST: gitlab.company.com
```

## Security

- **Runs on YOUR runners**: Code never leaves your GitLab CI environment
- **Secrets in CI/CD Variables**: API keys stored securely
- **Service account isolation**: Dedicated account for OpenCode operations
- **Audit trail**: All pipeline runs visible in CI/CD → Pipelines

## Troubleshooting

### Pipeline Not Triggering

1. Check webhook configuration
2. Verify trigger rules in `.gitlab-ci.yml`
3. Check CI/CD is enabled for the project

### Authentication Errors

1. Verify `GITLAB_TOKEN_OPENCODE` has correct scopes
2. Check token hasn't expired
3. Verify `GITLAB_HOST` is correct

### OpenCode Errors

1. Check `ANTHROPIC_API_KEY` is set correctly
2. Verify auth.json is created properly
3. Check pipeline logs for specific errors

## Integration with aidevops

When using aidevops workflows:

1. **Branch naming**: Configure OpenCode to use aidevops conventions
2. **MR format**: Use custom prompts for aidevops-style MR descriptions
3. **Quality checks**: OpenCode MRs trigger your existing CI pipelines

## Comparison with GitHub Integration

| Feature | GitHub | GitLab |
|---------|--------|--------|
| Trigger command | `/oc` or `/opencode` | `@opencode` |
| Setup method | GitHub App + workflow | CI/CD pipeline |
| Line-specific reviews | Yes (Files tab) | Limited |
| Auto-setup | `opencode github install` | Manual |

## Related

- **GitHub integration**: `git/opencode-github.md`
- **GitLab CLI**: `git/gitlab-cli.md`
- **Git workflow**: `workflows/git-workflow.md`
