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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

## Managed runner alternatives

GitHub-hosted runners are the default, but a single `runs-on:` label change can move any
job onto a third-party managed runner pool. For token-heavy or long-running CI, the cost
delta is worth checking before scaling the default pool.

### Ubicloud runners (~10x cheaper, one-line migration)

Ubicloud provisions managed GitHub Actions runners on its own x64 / arm64 bare metal at
~10x lower per-minute cost than `ubuntu-latest`. Image parity comes from the official
`actions/runner-images` packer templates (x64) and a Ubicloud-built image based on the
partner templates (arm64).

| Label | vCPU | Memory | Disk | $/min |
|-------|------|--------|------|-------|
| `ubicloud-standard-2` / `ubicloud` | 2 | 8 GB | 75 GB | 0.0008 |
| `ubicloud-standard-4` | 4 | 16 GB | 150 GB | 0.0016 |
| `ubicloud-standard-8` | 8 | 32 GB | 200 GB | 0.0032 |
| `ubicloud-standard-16` | 16 | 64 GB | 300 GB | 0.0064 |
| `ubicloud-standard-2-arm` / `ubicloud-arm` | 2 arm64 | 6 GB | 86 GB | 0.0008 |
| `ubicloud-standard-8-arm` | 8 arm64 | 24 GB | 200 GB | 0.0032 |

Pattern: `ubicloud-standard-{vcpu}[-arm][-ubuntu-{2204|2404}]`. Default OS since
2025-11-23 is Ubuntu 24.04; pin with `-ubuntu-2204` if a workflow still needs 22.04.

Migration:

```yaml
jobs:
  test:
    runs-on: ubicloud-standard-2   # was: ubuntu-latest — same spec, ~10x cheaper
    steps: [...]
```

Setup: install the **Ubicloud Managed Runners** GitHub App on the repo or org, add billing
in the Ubicloud console, then change the label. Every account gets a $1/month credit
(~1,250 minutes of 2-vCPU runner time). Jobs that access private services behind a firewall
should allowlist egress IPs from `https://api.ubicloud.com/ips-v4`.

Full runner integration details, hosted-vs-self-managed trade-offs, and the rest of the
Ubicloud product surface: `services/hosting/ubicloud.md`.
