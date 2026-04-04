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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Snyk Security Platform Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Developer security platform (SCA, SAST, Container, IaC)
- **Install**: `brew tap snyk/tap && brew install snyk-cli` or `npm install -g snyk`
- **Auth**: `snyk auth` (OAuth) or `SNYK_TOKEN` env var
- **Config**: `configs/snyk-config.json` (copy from `configs/snyk-config.json.txt`)
- **Helper**: `snyk-helper.sh [install|auth|status|test|code|container|iac|full|sbom|mcp] [target] [org]`
- **Scan types**: `snyk test` (deps), `snyk code test` (SAST), `snyk container test` (images), `snyk iac test` (IaC)
- **Severity**: critical > high > medium > low
- **MCP**: `snyk mcp` — tools: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan, snyk_sbom_scan, snyk_aibom, snyk_trust, snyk_auth, snyk_logout, snyk_version
- **API**: `https://api.snyk.io/rest/` (EU: api.eu.snyk.io, AU: api.au.snyk.io)

<!-- AI-CONTEXT-END -->

## Usage

```bash
# Common scans via helper
snyk-helper.sh test                        # dependency scan (SCA)
snyk-helper.sh code                        # SAST
snyk-helper.sh container nginx:latest      # container image
snyk-helper.sh iac ./terraform/            # IaC
snyk-helper.sh full                        # all scans
snyk-helper.sh monitor . my-org my-project # continuous monitoring
snyk-helper.sh sbom . cyclonedx1.4+json sbom.json  # SBOM

# Direct CLI options
snyk test --all-projects                                      # monorepo
snyk test --severity-threshold=high --json > results.json    # CI/CD gate
snyk test --prune-repeated-subdependencies                    # large projects
snyk container test my-app:latest --file=Dockerfile --exclude-base-image-vulns
snyk iac test --rules=./custom-rules/
```

## Output Formats

```bash
snyk test --json > results.json          # JSON
snyk test --sarif > results.sarif        # SARIF (IDE/CI)
snyk test --json | snyk-to-html -o results.html
```

## CI/CD Integration

### GitHub Actions

```yaml
- uses: snyk/actions/node@master
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
  with:
    args: --severity-threshold=high
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: snyk.sarif
```

### Generic CI Script

```bash
snyk auth "$SNYK_TOKEN"
snyk test --severity-threshold=high --json > snyk-results.json || true
snyk code test --severity-threshold=high || true
snyk monitor --org="$SNYK_ORG" --project-tags=env:$CI_ENVIRONMENT
if jq -e '.vulnerabilities | map(select(.severity == "high" or .severity == "critical")) | length > 0' snyk-results.json; then
    echo "High or critical vulnerabilities found!"; exit 1
fi
```

## MCP Config

```json
{
  "mcpServers": {
    "snyk": {
      "command": "snyk",
      "args": ["mcp"],
      "env": { "SNYK_TOKEN": "${SNYK_TOKEN}", "SNYK_ORG": "${SNYK_ORG}" }
    }
  }
}
```

## Supported Languages

- **SCA**: npm, Yarn, pnpm, pip, Poetry, Maven, Gradle, NuGet, Go modules, Composer, Bundler, CocoaPods, Swift PM, 40+ more
- **SAST**: JavaScript/TypeScript, Python, Java, Go, C#, PHP, Ruby, Apex
- **IaC**: Terraform (HCL, plan files), CloudFormation, Kubernetes, Azure ARM, Helm

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNYK_TOKEN` | API token for authentication |
| `SNYK_ORG` | Default organization ID |
| `SNYK_API` | Custom API URL (regional/self-hosted) |
| `SNYK_DISABLE_ANALYTICS` | Disable usage analytics |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Auth failed | `snyk auth` or check `snyk config get api` |
| Scan timeout | `snyk test --timeout=600` |
| No supported files | `snyk test --file=package.json` |
| Rate limiting | `snyk test --prune-repeated-subdependencies` |

**Resources**: [docs.snyk.io](https://docs.snyk.io/) · [status.snyk.io](https://status.snyk.io/) · [apidocs.snyk.io](https://apidocs.snyk.io/)
