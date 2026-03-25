---
description: Snyk security scanning for vulnerabilities
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

# Snyk Security Platform Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Developer security platform (SCA, SAST, Container, IaC)
- **Install**: `brew tap snyk/tap && brew install snyk-cli` or `npm install -g snyk`
- **Auth**: `snyk auth` (OAuth) or `SNYK_TOKEN` env var
- **Config**: `configs/snyk-config.json`
- **Commands**: `snyk-helper.sh [install|auth|status|test|code|container|iac|full|sbom|mcp] [target] [org]`
- **Scan types**: `snyk test` (deps), `snyk code test` (SAST), `snyk container test` (images), `snyk iac test` (IaC)
- **Severity levels**: critical > high > medium > low
- **MCP**: `snyk mcp` — tools: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan
- **API**: `https://api.snyk.io/rest/` (EU: api.eu.snyk.io, AU: api.au.snyk.io)

<!-- AI-CONTEXT-END -->

## Scan Types

| Scan Type | Description | Command |
|-----------|-------------|---------|
| **Snyk Open Source (SCA)** | Vulnerabilities in open-source dependencies | `snyk test` |
| **Snyk Code (SAST)** | Static analysis of source code | `snyk code test` |
| **Snyk Container** | Container image vulnerability scanning | `snyk container test` |
| **Snyk IaC** | Infrastructure as Code misconfiguration detection | `snyk iac test` |

## Installation & Auth

```bash
# Install
./.agents/scripts/snyk-helper.sh install
# Or manually:
brew tap snyk/tap && brew install snyk-cli
npm install -g snyk

# Auth (OAuth for local, env var for CI/CD)
./.agents/scripts/snyk-helper.sh auth
export SNYK_TOKEN="your-api-token"  # from https://app.snyk.io/account

# Config
cp configs/snyk-config.json.txt configs/snyk-config.json
```

## Usage

```bash
# Status and basic scans
./.agents/scripts/snyk-helper.sh status
./.agents/scripts/snyk-helper.sh test                        # dependency scan
./.agents/scripts/snyk-helper.sh code                        # SAST
./.agents/scripts/snyk-helper.sh container nginx:latest      # container
./.agents/scripts/snyk-helper.sh iac ./terraform/            # IaC
./.agents/scripts/snyk-helper.sh full                        # all scans

# Advanced options
snyk test --all-projects                                      # monorepo
snyk test --severity-threshold=high --json > results.json    # CI/CD
snyk test --prune-repeated-subdependencies                    # large projects
snyk container test my-app:latest --file=Dockerfile --exclude-base-image-vulns
snyk iac test --rules=./custom-rules/

# Monitoring
./.agents/scripts/snyk-helper.sh monitor . my-org my-project-name

# SBOM generation
./.agents/scripts/snyk-helper.sh sbom . cyclonedx1.4+json sbom.json
./.agents/scripts/snyk-helper.sh sbom . spdx2.3+json sbom-spdx.json
```

## Severity Levels & Thresholds

| Severity | Action | CLI flag |
|----------|--------|----------|
| **Critical** | Immediate fix | `--severity-threshold=critical` |
| **High** | Fix ASAP | `--severity-threshold=high` |
| **Medium** | Plan remediation | `--severity-threshold=medium` |
| **Low** | Next maintenance | `--severity-threshold=low` (default) |

## Output Formats

```bash
snyk test --json > results.json          # JSON
snyk test --sarif > results.sarif        # SARIF (IDE/CI integration)
snyk code test --sarif > code.sarif
snyk test --json | snyk-to-html -o results.html  # HTML report
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Snyk Security Scan
on: [push, pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Snyk
        uses: snyk/actions/node@master
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high
      - name: Upload SARIF
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: snyk.sarif
```

### GitLab CI

```yaml
snyk-scan:
  image: snyk/snyk:alpine
  script:
    - snyk auth $SNYK_TOKEN
    - snyk test --severity-threshold=high
    - snyk monitor
  only:
    - main
    - merge_requests
```

### Generic CI Script

```bash
#!/bin/bash
set -e
npm install -g snyk
snyk auth "$SNYK_TOKEN"
snyk test --severity-threshold=high --json > snyk-results.json || true
snyk code test --severity-threshold=high || true
snyk monitor --org="$SNYK_ORG" --project-tags=env:$CI_ENVIRONMENT
if jq -e '.vulnerabilities | map(select(.severity == "high" or .severity == "critical")) | length > 0' snyk-results.json; then
    echo "High or critical vulnerabilities found!"
    exit 1
fi
```

## MCP Integration

```json
{
  "mcpServers": {
    "snyk": {
      "command": "snyk",
      "args": ["mcp"],
      "env": {
        "SNYK_TOKEN": "${SNYK_TOKEN}",
        "SNYK_ORG": "${SNYK_ORG}"
      }
    }
  }
}
```

**MCP tools**: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan, snyk_sbom_scan, snyk_aibom, snyk_trust, snyk_auth, snyk_logout, snyk_version

```bash
snyk mcp  # or: ./.agents/scripts/snyk-helper.sh mcp
```

## Supported Languages & Formats

**SCA (Open Source)**: npm, Yarn, pnpm, pip, Poetry, Pipenv, Maven, Gradle, NuGet, Go modules, Composer, Bundler, CocoaPods, Swift Package Manager, and 40+ more.

**SAST (Code)**: JavaScript/TypeScript, Python, Java, Go, C#, PHP, Ruby, Apex, and more.

**IaC**: Terraform (HCL, plan files), CloudFormation, Kubernetes manifests, Azure ARM, Helm charts.

## Configuration

```bash
snyk config set org=your-org-id
export SNYK_SEVERITY_THRESHOLD=high
```

**CI/CD best practices**: Use Service Accounts for automation (Enterprise), set severity thresholds, monitor trends with project snapshots, tag projects for filtering, generate SBOMs for compliance.

## API Reference

```bash
# Base URL: https://api.snyk.io/rest/
# EU: https://api.eu.snyk.io | AU: https://api.au.snyk.io

curl -H "Authorization: token $SNYK_TOKEN" \
     -H "Content-Type: application/vnd.api+json" \
     "https://api.snyk.io/rest/orgs/{org_id}/projects?version=2024-06-10"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Auth failed | `snyk auth` or check `snyk config get api` |
| Scan timeout | `snyk test --timeout=600` |
| No supported files | `snyk test --file=package.json` |
| Rate limiting | `snyk test --prune-repeated-subdependencies` |

**Resources**: [docs.snyk.io](https://docs.snyk.io/) · [status.snyk.io](https://status.snyk.io/) · [apidocs.snyk.io](https://apidocs.snyk.io/)

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNYK_TOKEN` | API token for authentication |
| `SNYK_ORG` | Default organization ID |
| `SNYK_API` | Custom API URL (regional/self-hosted) |
| `SNYK_DISABLE_ANALYTICS` | Disable usage analytics |
