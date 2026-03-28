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
- **Workflow Position**: `/linters-local` -> `/code-audit-remote` -> `/pr` summary

```bash
# Run all remote audits
bash ~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]

# Individual services
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh review
bash ~/.aidevops/agents/scripts/codacy-cli.sh analyze
bash ~/.aidevops/agents/scripts/sonarcloud-cli.sh analyze
```

<!-- AI-CONTEXT-END -->

## Services

| Service | Focus | Strengths | API |
|---------|-------|-----------|-----|
| CodeRabbit | AI-powered code reviews | Context-aware suggestions, security analysis, best practices | REST + MCP |
| Codacy | Code quality analysis | 40+ languages, auto-fix suggestions, team collaboration | REST + CLI |
| SonarCloud | Security & maintainability | Industry standard rules, quality gates, tech debt tracking | Web API |

### Service-Specific Commands

```bash
# CodeRabbit
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh review
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh analyze .agents/scripts/

# Codacy
bash ~/.aidevops/agents/scripts/codacy-cli.sh analyze
bash ~/.aidevops/agents/scripts/codacy-cli.sh upload results.sarif

# SonarCloud
bash ~/.aidevops/agents/scripts/sonarcloud-cli.sh analyze
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&ps=1" | jq '.total'
```

## Usage

```bash
# Comprehensive audit across all services
bash ~/.aidevops/agents/scripts/code-audit-helper.sh audit my-repository

# Generate detailed report
bash ~/.aidevops/agents/scripts/code-audit-helper.sh report my-repository audit-report.json

# Per-service via helper (pattern: [service]-[action] [account] [target])
bash ~/.aidevops/agents/scripts/code-audit-helper.sh coderabbit-repos personal
bash ~/.aidevops/agents/scripts/code-audit-helper.sh coderabbit-analysis personal repo-id
bash ~/.aidevops/agents/scripts/code-audit-helper.sh codacy-repos organization
bash ~/.aidevops/agents/scripts/code-audit-helper.sh codacy-quality organization my-repo
bash ~/.aidevops/agents/scripts/code-audit-helper.sh sonarcloud-projects personal
bash ~/.aidevops/agents/scripts/code-audit-helper.sh sonarcloud-measures personal project-key
```

## Output Format

Reports follow this structure per service:

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
- **Bugs**: 0 | **Vulnerabilities**: 0
- **Code Smells**: 1 (S1192 - repeated string)
- **Technical Debt**: 15 minutes
```

## Quality Gates

| Metric | Minimum | Target |
|--------|---------|--------|
| Code Coverage | 80% | 90% |
| Bugs | 0 major | 0 total |
| Vulnerabilities | 0 high | 0 total |
| Code Smells | <10 major | <5 total |
| Duplicated Lines | <3% | <1% |

Gate config (`fail_build: true` for coverage <80% and high-severity security hotspots).

## MCP Integration

```bash
# Start MCP servers for real-time analysis during development
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp codacy 3004
bash ~/.aidevops/agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005
```

MCP enables: real-time code analysis, automated quality reports, security vulnerability detection, context-aware review suggestions, and quality trend analysis.

## CI/CD Integration (GitHub Actions)

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
          bash .agents/scripts/code-audit-helper.sh audit ${{ github.repository }}
          bash .agents/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: audit-report
          path: audit-report.json
```

## Configuration

```bash
# Copy template, then edit with your service API tokens
cp configs/code-audit-config.json.txt configs/code-audit-config.json
```

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
