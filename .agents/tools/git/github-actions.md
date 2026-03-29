---
description: GitHub Actions CI/CD workflow setup and management
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# GitHub Actions Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Workflow File**: `.github/workflows/code-quality.yml`
- **Triggers**: Push to main/develop, PRs to main
- **Jobs**: Framework validation, SonarCloud analysis, Codacy analysis
- **Required Secrets**: `SONAR_TOKEN` (configured), `CODACY_API_TOKEN` (needs setup)
- **Auto-Provided**: `GITHUB_TOKEN` by GitHub
- **SonarCloud Dashboard**: https://sonarcloud.io/project/overview?id=marcusquinn_aidevops
- **Codacy Dashboard**: https://app.codacy.com/gh/marcusquinn/aidevops
- **Actions URL**: https://github.com/marcusquinn/aidevops/actions
- **Add Secrets**: Repository Settings → Secrets and variables → Actions

<!-- AI-CONTEXT-END -->

## Required Secrets

| Secret | Status | Source |
|--------|--------|--------|
| `SONAR_TOKEN` | Configured | https://sonarcloud.io/account/security |
| `CODACY_API_TOKEN` | Needs setup | https://app.codacy.com/account/api-tokens |
| `GITHUB_TOKEN` | Auto-provided | GitHub |

## Add CODACY_API_TOKEN

1. Go to https://github.com/marcusquinn/aidevops/settings/secrets/actions
2. Click "New repository secret"
3. Name: `CODACY_API_TOKEN` — Value: token from secure local storage

## Workflow Triggers

- Push to main or develop → full analysis
- Pull Request to main → full analysis
- Jobs: Framework Validation, SonarCloud Analysis, Codacy Analysis (conditional on token)

## Concurrent Push Patterns

When workflows commit and push, concurrent runs cause race conditions. Use:

### Full Retry (external repos, wiki sync)

```yaml
for i in 1 2 3; do
  git pull --rebase origin main || true
  if git push; then exit 0; fi
  sleep $((i * 5))  # exponential backoff: 5s, 10s, 15s
done
exit 1
```

### Simple (same-repo auto-fixes, release workflows)

```yaml
git pull --rebase origin main || true
git push
```

| Scenario | Pattern |
|----------|---------|
| Pushing to external repo | Full retry |
| Auto-fix commits to same repo | Simple |
| Wiki sync | Full retry |
| Release workflows | Simple |

- Always `git pull --rebase` before pushing
- Use `|| true` after pull to continue if pull fails (empty repo, etc.)
- Exit with error after all retries fail to surface the issue
