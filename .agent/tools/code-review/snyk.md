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
- **MCP**: `snyk mcp` - tools: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan
- **API**: `https://api.snyk.io/rest/` (EU: api.eu.snyk.io, AU: api.au.snyk.io)
<!-- AI-CONTEXT-END -->

Comprehensive developer security platform for finding and fixing vulnerabilities in code, dependencies, containers, and infrastructure as code.

## Overview

Snyk provides four core security scanning capabilities:

| Scan Type | Description | Command |
|-----------|-------------|---------|
| **Snyk Open Source (SCA)** | Find vulnerabilities in open-source dependencies | `snyk test` |
| **Snyk Code (SAST)** | Static Application Security Testing for source code | `snyk code test` |
| **Snyk Container** | Container image vulnerability scanning | `snyk container test` |
| **Snyk IaC** | Infrastructure as Code misconfiguration detection | `snyk iac test` |

## Quick Start

### Installation

```bash
# Install via the helper script
./.agent/scripts/snyk-helper.sh install

# Or install manually:
# macOS (Homebrew)
brew tap snyk/tap && brew install snyk-cli

# npm/Yarn
npm install -g snyk

# Direct binary download (macOS)
curl --compressed https://downloads.snyk.io/cli/stable/snyk-macos -o /usr/local/bin/snyk
chmod +x /usr/local/bin/snyk
```

### Authentication

```bash
# Interactive OAuth authentication (recommended for local use)
./.agent/scripts/snyk-helper.sh auth

# Or set environment variable (recommended for CI/CD)
export SNYK_TOKEN="your-api-token"

# Get your API token from: https://app.snyk.io/account
```

### Configuration

```bash
# Copy the configuration template
cp configs/snyk-config.json.txt configs/snyk-config.json

# Edit with your organization details
```

## Usage Examples

### Basic Scanning

```bash
# Check status and authentication
./.agent/scripts/snyk-helper.sh status

# Scan current directory for dependency vulnerabilities
./.agent/scripts/snyk-helper.sh test

# Scan source code for security issues
./.agent/scripts/snyk-helper.sh code

# Scan a container image
./.agent/scripts/snyk-helper.sh container nginx:latest

# Scan Infrastructure as Code files
./.agent/scripts/snyk-helper.sh iac ./terraform/

# Run all security scans
./.agent/scripts/snyk-helper.sh full
```

### Advanced Scanning

```bash
# Scan with specific organization
./.agent/scripts/snyk-helper.sh test . my-org

# Scan with JSON output for CI/CD
./.agent/scripts/snyk-helper.sh test . "" "--json"

# Scan with severity threshold
./.agent/scripts/snyk-helper.sh test . "" "--severity-threshold=critical"

# Scan all projects in a monorepo
./.agent/scripts/snyk-helper.sh test . "" "--all-projects"

# Scan container with Dockerfile context
./.agent/scripts/snyk-helper.sh container my-image:tag "" "--file=Dockerfile"
```

### Continuous Monitoring

```bash
# Create project snapshot for monitoring
./.agent/scripts/snyk-helper.sh monitor . my-org my-project-name

# Monitor container image
snyk container monitor nginx:latest --org=my-org

# View monitored projects at: https://app.snyk.io
```

### SBOM Generation

```bash
# Generate CycloneDX SBOM (default)
./.agent/scripts/snyk-helper.sh sbom . cyclonedx1.4+json sbom.json

# Generate SPDX SBOM
./.agent/scripts/snyk-helper.sh sbom . spdx2.3+json sbom-spdx.json
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
      
      - name: Run Snyk to check for vulnerabilities
        uses: snyk/actions/node@master
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high
      
      - name: Upload SARIF file
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

### Generic CI/CD Script

```bash
#!/bin/bash
# ci-security-scan.sh

set -e

# Install Snyk CLI
npm install -g snyk

# Authenticate
snyk auth "$SNYK_TOKEN"

# Run dependency scan
snyk test --severity-threshold=high --json > snyk-results.json || true

# Run code scan
snyk code test --severity-threshold=high || true

# Create monitoring snapshot
snyk monitor --org="$SNYK_ORG" --project-tags=env:$CI_ENVIRONMENT

# Check for high/critical issues
if jq -e '.vulnerabilities | map(select(.severity == "high" or .severity == "critical")) | length > 0' snyk-results.json; then
    echo "High or critical vulnerabilities found!"
    exit 1
fi
```

## MCP Integration

Snyk provides an official MCP server for AI assistant integration.

### MCP Configuration

Add to your MCP configuration file:

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

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `snyk_sca_scan` | Open Source vulnerability scan |
| `snyk_code_scan` | Source code security scan |
| `snyk_iac_scan` | Infrastructure as Code scan |
| `snyk_container_scan` | Container image scan |
| `snyk_sbom_scan` | SBOM file scan |
| `snyk_aibom` | Create AI Bill of Materials |
| `snyk_trust` | Trust folder before scanning |
| `snyk_auth` | Authentication |
| `snyk_logout` | Logout |
| `snyk_version` | Version information |

### Starting MCP Server

```bash
# Start directly
snyk mcp

# Or via helper script
./.agent/scripts/snyk-helper.sh mcp
```

## Severity Levels

Snyk categorizes vulnerabilities by severity:

| Severity | Description | Recommended Action |
|----------|-------------|-------------------|
| **Critical** | Actively exploited, high impact | Immediate fix required |
| **High** | Easily exploitable, significant impact | Fix as soon as possible |
| **Medium** | Requires specific conditions to exploit | Plan for remediation |
| **Low** | Limited impact or difficult to exploit | Fix in next maintenance cycle |

### Severity Threshold Options

```bash
# Only report critical issues
snyk test --severity-threshold=critical

# Report high and critical issues
snyk test --severity-threshold=high

# Report medium, high, and critical issues
snyk test --severity-threshold=medium

# Report all issues (default)
snyk test --severity-threshold=low
```

## Output Formats

### JSON Output

```bash
# Standard JSON output
snyk test --json > results.json

# Pretty printed JSON
snyk test --json | jq .
```

### SARIF Output (for IDE/CI integration)

```bash
snyk test --sarif > results.sarif
snyk code test --sarif > code-results.sarif
```

### HTML Report

```bash
snyk test --json | snyk-to-html -o results.html
```

## Scan Types Deep Dive

### Snyk Open Source (SCA)

Scans project dependencies for known vulnerabilities.

**Supported Package Managers:**

- npm, Yarn, pnpm (JavaScript/Node.js)
- pip, Poetry, Pipenv (Python)
- Maven, Gradle (Java)
- NuGet (.NET)
- Go modules
- Composer (PHP)
- Bundler (Ruby)
- CocoaPods, Swift Package Manager (iOS)
- And 40+ more

```bash
# Scan single project
snyk test

# Scan all projects in monorepo
snyk test --all-projects

# Scan with specific manifest file
snyk test --file=package.json

# Scan with detection depth
snyk test --detection-depth=4
```

### Snyk Code (SAST)

Static analysis of source code for security vulnerabilities.

**Supported Languages:**

- JavaScript/TypeScript
- Python
- Java
- Go
- C#
- PHP
- Ruby
- Apex
- And more

```bash
# Scan current directory
snyk code test

# Scan specific path
snyk code test ./src/

# Output as SARIF
snyk code test --sarif-file-output=code.sarif
```

### Snyk Container

Scans container images for vulnerabilities.

```bash
# Scan from registry
snyk container test nginx:latest

# Scan local image
snyk container test my-app:local

# Scan with Dockerfile for better recommendations
snyk container test my-app:latest --file=Dockerfile

# Exclude base image vulnerabilities
snyk container test my-app:latest --exclude-base-image-vulns

# Specify platform
snyk container test my-app:latest --platform=linux/arm64
```

### Snyk IaC

Scans Infrastructure as Code for misconfigurations.

**Supported Formats:**

- Terraform (HCL, plan files)
- CloudFormation
- Kubernetes manifests
- Azure Resource Manager (ARM)
- Helm charts

```bash
# Scan Terraform files
snyk iac test ./terraform/

# Scan Kubernetes manifests
snyk iac test ./k8s/

# Scan specific file
snyk iac test main.tf

# Use custom rules
snyk iac test --rules=./custom-rules/
```

## Best Practices

### Security Workflow

1. **Development**: Run scans locally before committing
2. **CI/CD**: Automate scans in pipelines with severity thresholds
3. **Monitoring**: Create snapshots for continuous monitoring
4. **Remediation**: Prioritize fixes by severity and exploitability

### Recommended Configuration

```bash
# Set organization default
snyk config set org=your-org-id

# Enable analytics (optional)
snyk config set disable-analytics=false

# Configure severity threshold
export SNYK_SEVERITY_THRESHOLD=high
```

### CI/CD Best Practices

1. **Use Service Accounts** for automation (Enterprise feature)
2. **Set severity thresholds** to avoid blocking on low-severity issues
3. **Monitor trends** with project snapshots
4. **Tag projects** for organization and filtering
5. **Generate SBOMs** for compliance and auditing

## API Reference

### REST API

```bash
# Base URL
https://api.snyk.io/rest/

# Example: Get organization projects
curl -H "Authorization: token $SNYK_TOKEN" \
     -H "Content-Type: application/vnd.api+json" \
     "https://api.snyk.io/rest/orgs/{org_id}/projects?version=2024-06-10"
```

### Regional URLs

| Region | API URL |
|--------|---------|
| US (Default) | `https://api.snyk.io` |
| EU | `https://api.eu.snyk.io` |
| AU | `https://api.au.snyk.io` |

## Troubleshooting

### Common Issues

**Authentication Failed:**

```bash
# Re-authenticate
snyk auth

# Check authentication status
snyk config get api
```

**Scan Timeout:**

```bash
# Increase timeout
snyk test --timeout=600
```

**No Supported Files Found:**

```bash
# Specify manifest file explicitly
snyk test --file=package.json

# Check supported languages
snyk test --help
```

**Rate Limiting:**

```bash
# Use --prune-repeated-subdependencies for large projects
snyk test --prune-repeated-subdependencies
```

### Getting Help

- **Documentation**: [https://docs.snyk.io/](https://docs.snyk.io/)
- **Status Page**: [https://status.snyk.io/](https://status.snyk.io/)
- **Support**: [https://support.snyk.io/](https://support.snyk.io/)
- **API Reference**: [https://apidocs.snyk.io/](https://apidocs.snyk.io/)

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNYK_TOKEN` | API token for authentication |
| `SNYK_ORG` | Default organization ID |
| `SNYK_API` | Custom API URL (for regional/self-hosted) |
| `SNYK_CFG_ORG` | Organization from config file |
| `SNYK_DISABLE_ANALYTICS` | Disable usage analytics |

## Integration with AI DevOps Framework

The Snyk integration provides:

- **Unified command interface** via `snyk-helper.sh`
- **Configuration management** through JSON templates
- **MCP server support** for AI assistant integration
- **CI/CD templates** for automated security scanning
- **Quality gate integration** with other framework tools

### Quick Reference

```bash
# Status check
./.agent/scripts/snyk-helper.sh status

# Full security scan
./.agent/scripts/snyk-helper.sh full

# List configured organizations
./.agent/scripts/snyk-helper.sh accounts

# Start MCP server
./.agent/scripts/snyk-helper.sh mcp
```

---

**Snyk provides comprehensive developer-first security scanning, enabling teams to find and fix vulnerabilities throughout the software development lifecycle.**
