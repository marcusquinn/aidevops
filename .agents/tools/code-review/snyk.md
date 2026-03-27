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
- **Auth**: `snyk auth` (OAuth) or `SNYK_TOKEN` env var ([app.snyk.io/account](https://app.snyk.io/account))
- **Config**: `configs/snyk-config.json` — init: `cp configs/snyk-config.json.txt configs/snyk-config.json`
- **Helper**: `snyk-helper.sh [install|auth|status|test|code|container|iac|full|sbom|mcp|monitor] [target] [org]`
- **Severity**: critical > high > medium > low — `--severity-threshold={level}`
- **MCP**: `snyk mcp` — tools: snyk_sca_scan, snyk_code_scan, snyk_iac_scan, snyk_container_scan, snyk_sbom_scan, snyk_aibom, snyk_trust, snyk_auth, snyk_logout, snyk_version
- **API**: `https://api.snyk.io/rest/` (EU: `api.eu.snyk.io`, AU: `api.au.snyk.io`)

| Scan | Command | What it checks |
|------|---------|----------------|
| SCA (Open Source) | `snyk test` | Dependency vulnerabilities |
| SAST (Code) | `snyk code test` | Source code static analysis |
| Container | `snyk container test <image>` | Container image vulnerabilities |
| IaC | `snyk iac test <path>` | Infrastructure misconfigurations |

<!-- AI-CONTEXT-END -->

## Usage

```bash
# Helper shortcuts
snyk-helper.sh status
snyk-helper.sh test                        # dependency scan
snyk-helper.sh code                        # SAST
snyk-helper.sh container nginx:latest      # container
snyk-helper.sh iac ./terraform/            # IaC
snyk-helper.sh full                        # all scans

# Advanced
snyk test --all-projects                                    # monorepo
snyk test --severity-threshold=high --json > results.json   # CI/CD filtering
snyk test --prune-repeated-subdependencies                  # large projects
snyk container test my-app:latest --file=Dockerfile --exclude-base-image-vulns
snyk iac test --rules=./custom-rules/

# Monitoring & SBOM
snyk-helper.sh monitor . my-org my-project-name
snyk-helper.sh sbom . cyclonedx1.4+json sbom.json
snyk-helper.sh sbom . spdx2.3+json sbom-spdx.json

# Output formats
snyk test --json > results.json                        # JSON
snyk test --sarif > results.sarif                      # SARIF (IDE/CI)
snyk code test --sarif > code.sarif
snyk test --json | snyk-to-html -o results.html        # HTML report

# Configuration
snyk config set org=your-org-id
export SNYK_SEVERITY_THRESHOLD=high
```

## CI/CD Integration

**GitHub Actions** — use `snyk/actions/node@master` with `SNYK_TOKEN` secret, `--severity-threshold=high`, and upload SARIF via `github/codeql-action/upload-sarif@v3`.

**GitLab CI** — `snyk/snyk:alpine` image: `snyk auth $SNYK_TOKEN && snyk test --severity-threshold=high && snyk monitor`. Run on `main` and merge requests.

**Generic CI pattern** — Install → auth → `snyk test --severity-threshold=high --json > results.json || true` → `snyk code test || true` → `snyk monitor` → parse JSON for critical/high vulns to gate the build.

**Best practices**: Service Accounts for automation (Enterprise), severity thresholds, project snapshots for trends, project tags for filtering, SBOMs for compliance.

## MCP Configuration

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

**SCA**: npm, Yarn, pnpm, pip, Poetry, Pipenv, Maven, Gradle, NuGet, Go modules, Composer, Bundler, CocoaPods, Swift PM, and 40+ more.
**SAST**: JavaScript/TypeScript, Python, Java, Go, C#, PHP, Ruby, Apex, and more.
**IaC**: Terraform (HCL, plan files), CloudFormation, Kubernetes, Azure ARM, Helm.

## API

```bash
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

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNYK_TOKEN` | API token for authentication |
| `SNYK_ORG` | Default organization ID |
| `SNYK_API` | Custom API URL (regional/self-hosted) |
| `SNYK_DISABLE_ANALYTICS` | Disable usage analytics |

**Resources**: [docs.snyk.io](https://docs.snyk.io/) · [status.snyk.io](https://status.snyk.io/) · [apidocs.snyk.io](https://apidocs.snyk.io/)
