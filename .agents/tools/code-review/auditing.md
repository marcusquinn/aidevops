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

<!-- AI-CONTEXT-END -->

## Services

| Service | Focus | Strengths | MCP |
|---------|-------|-----------|-----|
| **CodeRabbit** | AI-powered code reviews | Context-aware reviews, security analysis | Port 3003 |
| **CodeFactor** | Automated quality analysis | Simple setup, clear metrics, GitHub integration | — |
| **Codacy** | Quality + security analysis | Comprehensive metrics, team collaboration | Port 3004 |
| **SonarCloud** | Industry-standard analysis | Comprehensive rules, quality gates | Port 3005 |

## Configuration

```bash
cp configs/code-audit-config.json.txt configs/code-audit-config.json
# Edit with your service API tokens
```

```json
{
  "services": {
    "coderabbit": { "accounts": { "personal": { "api_token": "...", "base_url": "https://api.coderabbit.ai/v1", "organization": "your-org" } } },
    "codacy": { "accounts": { "organization": { "api_token": "...", "base_url": "https://app.codacy.com/api/v3", "organization": "your-org" } } }
  }
}
```

## Usage

```bash
# Core commands
./.agents/scripts/code-audit-helper.sh services                    # List services
./.agents/scripts/code-audit-helper.sh audit my-repository         # Run audit
./.agents/scripts/code-audit-helper.sh report my-repo report.json  # Generate report

# Service-specific (pattern: {service}-repos, {service}-{action})
./.agents/scripts/code-audit-helper.sh coderabbit-repos personal
./.agents/scripts/code-audit-helper.sh coderabbit-analysis personal repo-id
./.agents/scripts/code-audit-helper.sh codacy-repos organization
./.agents/scripts/code-audit-helper.sh codacy-quality organization my-repo
./.agents/scripts/code-audit-helper.sh codefactor-repos personal
./.agents/scripts/code-audit-helper.sh codefactor-issues personal my-repo
./.agents/scripts/code-audit-helper.sh sonarcloud-projects personal
./.agents/scripts/code-audit-helper.sh sonarcloud-measures personal project-key

# MCP servers
./.agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003
./.agents/scripts/code-audit-helper.sh start-mcp codacy 3004    # https://github.com/codacy/codacy-mcp-server
./.agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005 # https://github.com/SonarSource/sonarqube-mcp-server
```

## Quality Gates

| Metric | Threshold | Fail Build |
|--------|-----------|------------|
| Code Coverage | ≥80% (target 90%) | Yes |
| Major Bugs | 0 | Yes |
| High Vulnerabilities | 0 | Yes |
| Security Hotspots | 0 high-severity | Yes |
| Duplicated Lines | ≤3% | No |

## CI/CD Integration

Add to a GitHub Actions workflow step:

```yaml
run: |
  ./.agents/scripts/code-audit-helper.sh audit ${{ github.repository }}
  ./.agents/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
```

Upload `audit-report.json` as an artifact via `actions/upload-artifact@v4`.

## Security

Store API tokens via `aidevops secret set NAME` (gopass) or `~/.config/aidevops/credentials.sh` (600 perms — never store tokens elsewhere). Use minimal-scope tokens. See `prompts/build.txt` for full secret-handling rules.
