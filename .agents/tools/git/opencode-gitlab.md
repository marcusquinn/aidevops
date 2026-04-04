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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode GitLab Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Trigger**: `@opencode` in any issue/MR comment
- **Runs on**: Your GitLab CI runners — code never leaves your environment
- **Docs**: <https://opencode.ai/docs/gitlab/>
- **Security**: API keys stored in CI/CD Variables (masked); all pipeline runs auditable in CI/CD > Pipelines

| Command | Result |
|---------|--------|
| `@opencode explain this` | AI analyzes issue/MR and replies |
| `@opencode fix this` | Creates branch, implements fix, opens MR |
| `@opencode review this MR` | Reviews code, suggests improvements |

**Requirements**: GitLab CI/CD enabled; CI/CD variables `ANTHROPIC_API_KEY`, `GITLAB_TOKEN_OPENCODE`, `GITLAB_HOST`; service account with `api` + `read_repository` + `write_repository` scopes.

<!-- AI-CONTEXT-END -->

## Installation

### Step 1: Create Service Account

Create a GitLab user or project access token with scopes: `api`, `read_repository`, `write_repository`.

### Step 2: Configure CI/CD Variables

Settings > CI/CD > Variables:

| Variable | Value | Protected | Masked |
|----------|-------|-----------|--------|
| `ANTHROPIC_API_KEY` | Your API key | Yes | Yes |
| `GITLAB_TOKEN_OPENCODE` | Service account token | Yes | Yes |
| `GITLAB_HOST` | `gitlab.com` or your self-hosted instance URL | No | No |

### Step 3: Create CI/CD Pipeline

Add to `.gitlab-ci.yml`:

```yaml
stages:
  - opencode

opencode:
  stage: opencode
  image: node:22-slim
  rules:
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
    # Setup OpenCode auth (supports multiple providers — remove unused entries)
    - mkdir -p ~/.local/share/opencode
    - |
      cat > ~/.local/share/opencode/auth.json << EOF
      {
        "anthropic": { "apiKey": "$ANTHROPIC_API_KEY" },
        "openai": { "apiKey": "$OPENAI_API_KEY" }
      }
      EOF
  script:
    # Override model with --model (e.g., anthropic/claude-sonnet-4-6)
    - opencode run "$AI_FLOW_INPUT"
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

**Webhook (optional)**: Settings > Webhooks > set URL to your pipeline trigger URL, trigger on Note events (issues and MRs) for automatic triggering on comments.

## Troubleshooting

| Problem | Checks |
|---------|--------|
| Pipeline not triggering | Webhook config, trigger rules in `.gitlab-ci.yml`, CI/CD enabled for project |
| Authentication errors | `GITLAB_TOKEN_OPENCODE` scopes, token expiry, `GITLAB_HOST` value |
| OpenCode errors | `ANTHROPIC_API_KEY` set correctly, `auth.json` created properly, pipeline logs |

## Integration with aidevops

- **Branch naming**: Configure OpenCode to use aidevops conventions (`feature/`, `bugfix/`, etc.)
- **MR format**: Use custom prompts for aidevops-style MR descriptions
- **Quality checks**: OpenCode MRs trigger your existing CI pipelines automatically

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
