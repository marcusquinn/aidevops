---
description: Setup guide for code quality services
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

# Code Quality Services Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- 4 platforms: CodeRabbit (AI reviews), CodeFactor (grading), Codacy (security), SonarCloud (enterprise)
- Setup time: ~5 min each, all use GitHub OAuth
- CodeRabbit: coderabbit.ai -> Add repo -> Enable PR reviews
- CodeFactor: codefactor.io -> Add repo -> Enable GitHub Checks
- Codacy: app.codacy.com -> Import repo -> Uses .codacy.yml
- SonarCloud: sonarcloud.io -> Create org -> Import project -> Get token -> Add `SONAR_TOKEN` secret
- Config files: .codacy.yml, sonar-project.properties (already in repo)
- Expected grades: CodeFactor A+, Codacy A, SonarCloud passed gate
- Troubleshooting: Check secrets, webhook configs, repo permissions

<!-- AI-CONTEXT-END -->

## Platform Setup

### 1. CodeRabbit (AI code reviews)

1. Sign up at <https://coderabbit.ai/> with GitHub
2. Authorize access, add repository
3. Enable automatic PR reviews

### 2. CodeFactor (quality grading)

1. Sign up at <https://www.codefactor.io/> with GitHub
2. Add repository
3. Enable GitHub Checks for PR integration

### 3. Codacy (security analysis)

1. Sign up at <https://app.codacy.com/> with GitHub
2. Import repository — uses the `.codacy.yml` already in the repo

### 4. SonarCloud (enterprise analysis)

1. Sign up at <https://sonarcloud.io/> with GitHub
2. Create organization linked to your GitHub account
3. Import project
4. Generate token: My Account > Security > Generate Token
5. Add GitHub secret: repo Settings > Secrets and variables > Actions > `SONAR_TOKEN`
6. Verify: push a commit, check Actions tab for successful analysis

## Analysis Coverage

| Platform | Focus areas |
|----------|-------------|
| CodeRabbit | AI code reviews, security vulnerabilities, best practices, performance |
| CodeFactor | Quality grading (A-F), cyclomatic complexity, technical debt, trends |
| Codacy | Security scanning, quality metrics, test coverage, coding standards |
| SonarCloud | Security hotspots, code smells, bug detection, duplication analysis |

## README Badges

```markdown
[![CodeRabbit](https://img.shields.io/badge/CodeRabbit-AI%20Reviews-blue)](https://coderabbit.ai)
```

```markdown
[![CodeFactor](https://www.codefactor.io/repository/github/marcusquinn/aidevops/badge)](https://www.codefactor.io/repository/github/marcusquinn/aidevops)
```

```markdown
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/[PROJECT_ID])](https://app.codacy.com/gh/marcusquinn/aidevops/dashboard)
```

```markdown
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=marcusquinn_aidevops&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=marcusquinn_aidevops)
```

## Expected Quality Scores

| Platform | Target | Notes |
|----------|--------|-------|
| CodeFactor | A+ | Code organization |
| Codacy | A | Shell scripts and docs |
| SonarCloud | Passed gate | Zero security issues |
| CodeRabbit | Positive feedback | Well-structured framework |

## Troubleshooting

**SonarCloud not running:**
Check `SONAR_TOKEN` secret is set, verify organization setup, check `sonar-project.properties`.

**CodeRabbit not reviewing:**
Ensure repo is added, check GitHub app permissions, verify PR triggers.

**CodeFactor not updating:**
Check repository connection, verify GitHub webhook, ensure repo is public or authorized.

**Codacy analysis issues:**
Check `.codacy.yml` configuration, verify import succeeded, check supported file types.
