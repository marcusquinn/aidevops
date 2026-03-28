---
description: Code auditing services and security analysis
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

# Code Auditing Services Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/code-audit-helper.sh`
- **Services**: CodeRabbit (AI reviews), CodeFactor (quality), Codacy (enterprise), SonarCloud (security)
- **Config**: `configs/code-audit-config.json`
- **Commands**: `services` | `audit [repo]` | `report [repo] [file]` | `start-mcp [service] [port]`
- **MCP Ports**: CodeRabbit (3003), Codacy (3004), SonarCloud (3005)
- **Quality Gates**: 80% coverage, 0 major bugs, 0 high vulnerabilities, <3% duplication
- **Service Commands**: `coderabbit-repos`, `codacy-repos`, `sonarcloud-projects`, `codefactor-repos`
- **CI/CD**: GitHub Actions integration with quality gate enforcement

<!-- AI-CONTEXT-END -->

## Services Overview

| Service | Focus | Strengths | MCP |
|---------|-------|-----------|-----|
| **CodeRabbit** | AI-powered code reviews | Context-aware reviews, security analysis | Port 3003 |
| **CodeFactor** | Automated quality analysis | Simple setup, clear metrics, GitHub integration | — |
| **Codacy** | Quality and security analysis | Comprehensive metrics, team collaboration, custom rules | Port 3004 |
| **SonarCloud** | Industry-standard quality/security | Comprehensive rules, quality gates | Port 3005 |

## Configuration

```bash
# Copy template and add API tokens
cp configs/code-audit-config.json.txt configs/code-audit-config.json
```

Config structure (see template for full schema):

```json
{
  "services": {
    "coderabbit": { "accounts": { "personal": { "api_token": "...", "base_url": "https://api.coderabbit.ai/v1", "organization": "your-org" } } },
    "codacy":     { "accounts": { "organization": { "api_token": "...", "base_url": "https://app.codacy.com/api/v3", "organization": "your-org" } } }
  }
}
```

## Usage

### Core Commands

```bash
# List configured services
./.agents/scripts/code-audit-helper.sh services

# Run audit across all services
./.agents/scripts/code-audit-helper.sh audit my-repository

# Generate report
./.agents/scripts/code-audit-helper.sh report my-repository audit-report.json
```

### Per-Service Commands

```bash
# CodeRabbit
./.agents/scripts/code-audit-helper.sh coderabbit-repos personal
./.agents/scripts/code-audit-helper.sh coderabbit-analysis personal repo-id
./.agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003

# CodeFactor
./.agents/scripts/code-audit-helper.sh codefactor-repos personal
./.agents/scripts/code-audit-helper.sh codefactor-issues personal my-repo
curl -H "X-CF-TOKEN: $API_TOKEN" https://www.codefactor.io/api/v1/repositories/my-repo

# Codacy
./.agents/scripts/code-audit-helper.sh codacy-repos organization
./.agents/scripts/code-audit-helper.sh codacy-quality organization my-repo
./.agents/scripts/code-audit-helper.sh start-mcp codacy 3004

# SonarCloud
./.agents/scripts/code-audit-helper.sh sonarcloud-projects personal
./.agents/scripts/code-audit-helper.sh sonarcloud-measures personal project-key
./.agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005
```

## Quality Gates & Metrics

| Metric | Threshold |
|--------|-----------|
| Code Coverage | Minimum 80%, target 90% |
| Code Smells | Maximum 10 major issues |
| Security Hotspots | Zero high-severity |
| Bugs | Zero major |
| Vulnerabilities | Zero high-severity |
| Duplicated Lines | Maximum 3% |

## MCP Integration

### Starting MCP Servers

```bash
./.agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003
./.agents/scripts/code-audit-helper.sh start-mcp codacy 3004    # https://github.com/codacy/codacy-mcp-server
./.agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005 # https://github.com/SonarSource/sonarqube-mcp-server
```

### CodeRabbit MCP Config

```json
{
  "coderabbit": {
    "command": "coderabbit-mcp-server",
    "args": ["--port", "3003"],
    "env": { "CODERABBIT_API_TOKEN": "your-token" }
  }
}
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Code Quality Audit
on: [push, pull_request]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Code Audit
        run: |
          ./.agents/scripts/code-audit-helper.sh audit ${{ github.repository }}
          ./.agents/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
      - name: Upload Report
        uses: actions/upload-artifact@v3
        with:
          name: audit-report
          path: audit-report.json
```

### Quality Gate Enforcement Script

```bash
#!/bin/bash
REPO_NAME="$1"
REPORT_FILE="audit-report-$(date +%Y%m%d-%H%M%S).json"

./.agents/scripts/code-audit-helper.sh audit "$REPO_NAME"
./.agents/scripts/code-audit-helper.sh report "$REPO_NAME" "$REPORT_FILE"

COVERAGE=$(jq -r '.coverage' "$REPORT_FILE")
BUGS=$(jq -r '.bugs' "$REPORT_FILE")
VULNERABILITIES=$(jq -r '.vulnerabilities' "$REPORT_FILE")

if (( $(echo "$COVERAGE < 80" | bc -l) )); then echo "Coverage below 80%: $COVERAGE%"; exit 1; fi
if (( BUGS > 0 )); then echo "Bugs found: $BUGS"; exit 1; fi
if (( VULNERABILITIES > 0 )); then echo "Vulnerabilities found: $VULNERABILITIES"; exit 1; fi

echo "All quality gates passed"
```

## Security & Best Practices

**API token hygiene:** Store tokens via `aidevops secret set NAME` (gopass) or `credentials.sh` (600 perms). Use minimal-scope tokens. Rotate regularly.

**Ongoing quality discipline:**
- Run security scans on every commit; track and remediate vulnerabilities promptly
- Scan dependencies and commits for accidentally exposed secrets
- Integrate quality gates into CI/CD to enforce standards automatically
- Monitor quality trends; create issues for regressions
