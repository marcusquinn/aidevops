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

- Platforms: CodeRabbit (AI PR review), CodeFactor (grade/trends), Codacy (quality/security), SonarCloud (quality gate)
- Setup time: ~5 minutes per platform, all via GitHub OAuth
- Existing config files: `.codacy.yml`, `sonar-project.properties`
- Targets: CodeFactor A+, Codacy A, SonarCloud passed gate, CodeRabbit useful PR feedback
- Deep dives: `coderabbit.md`, `codacy.md`, `tools.md`, `.agents/scripts/sonarcloud-cli.sh`

| Platform | Setup | Coverage |
|---|---|---|
| CodeRabbit | <https://coderabbit.ai/> → add repo → enable automatic PR reviews | AI review, security, best practices, performance |
| CodeFactor | <https://www.codefactor.io/> → add repo → enable GitHub Checks | A-F grade, cyclomatic complexity, technical debt, trends |
| Codacy | <https://app.codacy.com/> → import repo; uses `.codacy.yml` | Security scanning, quality metrics, test coverage, standards |
| SonarCloud | <https://sonarcloud.io/> → create org → import project → add `SONAR_TOKEN` GitHub secret | Security hotspots, bugs, code smells, duplication, quality gate |

<!-- AI-CONTEXT-END -->

## README Badges

| Platform | Badge |
|---|---|
| CodeRabbit | `[![CodeRabbit](https://img.shields.io/badge/CodeRabbit-AI%20Reviews-blue)](https://coderabbit.ai)` |
| CodeFactor | `[![CodeFactor](https://www.codefactor.io/repository/github/marcusquinn/aidevops/badge)](https://www.codefactor.io/repository/github/marcusquinn/aidevops)` |
| Codacy | `[![Codacy Badge](https://app.codacy.com/project/badge/Grade/[PROJECT_ID])](https://app.codacy.com/gh/marcusquinn/aidevops/dashboard)` |
| SonarCloud | `[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=marcusquinn_aidevops&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=marcusquinn_aidevops)` |

## Troubleshooting

| Problem | Checks |
|---|---|
| SonarCloud not running | Verify `SONAR_TOKEN`, organization setup, and `sonar-project.properties`. |
| CodeRabbit not reviewing | Ensure the repo is connected, app permissions are granted, and PR triggers are enabled. |
| CodeFactor not updating | Check the repo connection, webhook/GitHub Checks status, and repo authorization. |
| Codacy analysis issues | Check `.codacy.yml`, confirm import succeeded, and verify the file types are supported. |
