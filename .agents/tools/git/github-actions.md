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

- **Workflow**: `.github/workflows/code-quality.yml`
- **Triggers**: push to `main`/`develop`; pull requests to `main`
- **Jobs**: Framework Validation, SonarCloud Analysis, Codacy Analysis
- **Dashboards**: [SonarCloud](https://sonarcloud.io/project/overview?id=marcusquinn_aidevops) · [Codacy](https://app.codacy.com/gh/marcusquinn/aidevops) · [Actions](https://github.com/marcusquinn/aidevops/actions)
- **Add secret**: Repository Settings → Secrets and variables → Actions → New repository secret

## Secrets

| Secret | Status | Source |
|--------|--------|--------|
| `SONAR_TOKEN` | Configured | https://sonarcloud.io/account/security |
| `CODACY_API_TOKEN` | Needs setup | https://app.codacy.com/account/api-tokens |
| `GITHUB_TOKEN` | Auto-provided | GitHub |

## Concurrent Push Patterns

| Scenario | Pattern |
|----------|---------|
| Pushing to external repo | Full retry |
| Auto-fix commits to same repo | Simple |
| Wiki sync | Full retry |
| Release workflows | Simple |

### Full retry

```yaml
for i in 1 2 3; do
  git pull --rebase origin main || true
  if git push; then exit 0; fi
  sleep $((i * 5))  # exponential backoff: 5s, 10s, 15s
done
exit 1
```

### Simple

```yaml
git pull --rebase origin main || true
git push
```

- Always `git pull --rebase` before `git push`.
- Keep `|| true` on pull so empty-repo or no-op pull failures do not abort the workflow.
- Exit non-zero after retries fail so the workflow surfaces the push problem.
