---
description: Remote code auditing using external services (CodeRabbit, Codacy, SonarCloud)
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

# Code Audit Remote - External Quality Services

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Run remote code auditing via external service APIs
- **Services**: CodeRabbit (AI review), Codacy (quality), SonarCloud (security)
- **Script**: `~/.aidevops/agents/scripts/code-audit-helper.sh`
- **When**: PR review phase, after local linting passes

**Quick Commands**:

```bash
# Run all remote audits
bash ~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]

# Individual services
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh review
bash ~/.aidevops/agents/scripts/codacy-cli.sh analyze
bash ~/.aidevops/agents/scripts/sonarcloud-cli.sh analyze
```

**Workflow Position**: `/linters-local` -> `/code-audit-remote` -> `/pr` summary

<!-- AI-CONTEXT-END -->

## Purpose

The `/code-audit-remote` command calls external quality services via their APIs to provide:

1. **AI-powered code review** (CodeRabbit) - Contextual suggestions, security analysis
2. **Code quality analysis** (Codacy) - 40+ languages, auto-fix suggestions
3. **Security scanning** (SonarCloud) - Vulnerability detection, technical debt tracking

This complements `/linters-local` which runs fast, offline checks.

## Services Overview

### CodeRabbit

- **Focus**: AI-powered code reviews
- **Strengths**: Context-aware suggestions, security analysis, best practices
- **API**: REST API with MCP integration
- **Use Case**: Automated PR review with intelligent feedback

```bash
# Review current repository
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh review

# Analyze specific directory
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh analyze .agent/scripts/
```

### Codacy

- **Focus**: Comprehensive code quality analysis
- **Strengths**: 40+ languages, auto-fix for safe violations, team collaboration
- **API**: Full REST API with CLI support
- **Use Case**: Enterprise code quality management

```bash
# Run Codacy analysis
bash ~/.aidevops/agents/scripts/codacy-cli.sh analyze

# Upload results
bash ~/.aidevops/agents/scripts/codacy-cli.sh upload results.sarif
```

### SonarCloud

- **Focus**: Security and maintainability analysis
- **Strengths**: Industry standard, comprehensive rules, quality gates
- **API**: Extensive web API
- **Use Case**: Professional security and quality analysis

```bash
# Run SonarCloud analysis
bash ~/.aidevops/agents/scripts/sonarcloud-cli.sh analyze

# Check current issues
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&ps=1" | jq '.total'
```

## Usage

### Run All Remote Audits

```bash
# Comprehensive audit across all services
bash ~/.aidevops/agents/scripts/code-audit-helper.sh audit my-repository

# Generate detailed report
bash ~/.aidevops/agents/scripts/code-audit-helper.sh report my-repository audit-report.json
```

### Individual Service Commands

```bash
# CodeRabbit
bash ~/.aidevops/agents/scripts/code-audit-helper.sh coderabbit-repos personal
bash ~/.aidevops/agents/scripts/code-audit-helper.sh coderabbit-analysis personal repo-id

# Codacy
bash ~/.aidevops/agents/scripts/code-audit-helper.sh codacy-repos organization
bash ~/.aidevops/agents/scripts/code-audit-helper.sh codacy-quality organization my-repo

# SonarCloud
bash ~/.aidevops/agents/scripts/code-audit-helper.sh sonarcloud-projects personal
bash ~/.aidevops/agents/scripts/code-audit-helper.sh sonarcloud-measures personal project-key
```

## Output Format

```markdown
## Remote Audit Results

### CodeRabbit Analysis
- **Overall**: 2 suggestions (minor)
- **Security**: No issues detected
- **Best Practices**: Consider using async/await in `utils.js:45`

### Codacy Analysis
- **Grade**: A (maintained)
- **Issues**: 3 code patterns detected
- **Auto-fixable**: 2 issues can be auto-fixed

### SonarCloud Analysis
- **Quality Gate**: Passed
- **Bugs**: 0
- **Vulnerabilities**: 0
- **Code Smells**: 1 (S1192 - repeated string)
- **Technical Debt**: 15 minutes
```

## Quality Gates

### Recommended Thresholds

| Metric | Minimum | Target |
|--------|---------|--------|
| Code Coverage | 80% | 90% |
| Bugs | 0 major | 0 total |
| Vulnerabilities | 0 high | 0 total |
| Code Smells | <10 major | <5 total |
| Duplicated Lines | <3% | <1% |

### Gate Configuration

```json
{
  "quality_gates": {
    "code_coverage": {
      "minimum": 80,
      "target": 90,
      "fail_build": true
    },
    "security_hotspots": {
      "maximum": 0,
      "severity": "high",
      "fail_build": true
    }
  }
}
```

## MCP Integration

### Available MCP Servers

```bash
# Start CodeRabbit MCP server
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003

# Start Codacy MCP server
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp codacy 3004

# Start SonarCloud MCP server
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005
```

### AI Assistant Capabilities

With MCP integration, AI assistants can:

- **Real-time code analysis** during development
- **Automated quality reports** generation
- **Security vulnerability** detection and reporting
- **Code review assistance** with context-aware suggestions
- **Quality trend analysis** over time

## CI/CD Integration

### GitHub Actions

```yaml
name: Code Quality Audit
on: [push, pull_request]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Code Audit
        run: |
          bash .agent/scripts/code-audit-helper.sh audit ${{ github.repository }}
          bash .agent/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: audit-report
          path: audit-report.json
```

## Configuration

### Setup

```bash
# Copy template
cp configs/code-audit-config.json.txt configs/code-audit-config.json

# Edit with your service API tokens
```

### Multi-Service Configuration

```json
{
  "services": {
    "coderabbit": {
      "accounts": {
        "personal": {
          "api_token": "YOUR_CODERABBIT_API_TOKEN_HERE",
          "base_url": "https://api.coderabbit.ai/v1"
        }
      }
    },
    "codacy": {
      "accounts": {
        "organization": {
          "api_token": "YOUR_CODACY_API_TOKEN_HERE",
          "base_url": "https://app.codacy.com/api/v3"
        }
      }
    },
    "sonarcloud": {
      "accounts": {
        "personal": {
          "api_token": "YOUR_SONARCLOUD_TOKEN_HERE",
          "base_url": "https://sonarcloud.io/api"
        }
      }
    }
  }
}
```

## Related Workflows

- **Local linting**: `scripts/linters-local.sh`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Unified PR review**: `workflows/pr.md`
- **Auditing details**: `tools/code-review/auditing.md`
