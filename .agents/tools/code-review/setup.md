---
description: Setup guide for code quality services
mode: subagent
tools:
  read: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Code Quality Services Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

Setup time: ~5 min per platform via GitHub OAuth. Targets: CodeFactor A+, Codacy A, SonarCloud passed gate, CodeRabbit useful PR feedback.

| Platform | Setup | Coverage | Config |
|---|---|---|---|
| CodeRabbit | <https://coderabbit.ai/> → add repo → enable automatic PR reviews | AI review, security, best practices, performance | — |
| CodeFactor | <https://www.codefactor.io/> → add repo → enable GitHub Checks | A-F grade, cyclomatic complexity, technical debt, trends | — |
| Codacy | <https://app.codacy.com/> → import repo | Security scanning, quality metrics, test coverage, standards | `.codacy.yml` |
| SonarCloud | <https://sonarcloud.io/> → create org → import project → add `SONAR_TOKEN` GitHub secret | Security hotspots, bugs, code smells, duplication, quality gate | `sonar-project.properties` |

Deep dives: `coderabbit.md`, `codacy.md`, `tools.md`, `.agents/scripts/sonarcloud-cli.sh`

<!-- AI-CONTEXT-END -->

## README Badges

Replace `{owner}/{repo}` with your repository slug.

| Platform | Badge |
|---|---|
| CodeRabbit | `[![CodeRabbit](https://img.shields.io/badge/CodeRabbit-AI%20Reviews-blue)](https://coderabbit.ai)` |
| CodeFactor | `[![CodeFactor](https://www.codefactor.io/repository/github/{owner}/{repo}/badge)](https://www.codefactor.io/repository/github/{owner}/{repo})` |
| Codacy | `[![Codacy Badge](https://app.codacy.com/project/badge/Grade/[PROJECT_ID])](https://app.codacy.com/gh/{owner}/{repo}/dashboard)` |
| SonarCloud | `[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project={owner}_{repo}&metric=alert_status)](https://sonarcloud.io/summary/new_code?id={owner}_{repo})` |

## Troubleshooting

| Problem | Checks |
|---|---|
| SonarCloud not running | Verify `SONAR_TOKEN`, organization setup, and `sonar-project.properties`. |
| CodeRabbit not reviewing | Ensure repo is connected, app permissions granted, and PR triggers enabled. |
| CodeFactor not updating | Check repo connection, webhook/GitHub Checks status, and repo authorization. |
| Codacy analysis issues | Check `.codacy.yml`, confirm import succeeded, and verify file types are supported. |
