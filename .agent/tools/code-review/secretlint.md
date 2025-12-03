# Secretlint - Secret Detection Tool

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Pluggable linting tool to prevent committing credentials and secrets
- **Install**: `npm install secretlint @secretlint/secretlint-rule-preset-recommend --save-dev`
- **Quick start**: `npx @secretlint/quick-start "**/*"` (no install) or `docker run -v $(pwd):$(pwd) -w $(pwd) --rm secretlint/secretlint secretlint "**/*"`
- **Init**: `npx secretlint --init` creates `.secretlintrc.json`
- **Config**: `.secretlintrc.json` (rules), `.secretlintignore` (exclusions)
- **Commands**: `secretlint-helper.sh [install|init|scan|quick|docker|mask|sarif|hook|status|help]`
- **Exit codes**: 0=clean, 1=secrets found, 2=error
- **Output formats**: stylish (default), json, compact, table, sarif, mask-result
- **Detected secrets**: AWS, GCP, GitHub, OpenAI, Anthropic, Slack, npm, private keys, database strings, and more
- **Pre-commit**: Husky+lint-staged or native git hooks supported

<!-- AI-CONTEXT-END -->

Secretlint is a pluggable linting tool designed to prevent committing credentials and secrets to repositories. It provides an opt-in approach with comprehensive documentation for each detection rule.

## Overview

| Feature | Description |
|---------|-------------|
| **Secret Scanner** | Finds credentials in projects and reports them |
| **Project-Friendly** | Easy setup per-project with CI service integration |
| **Pre-Commit Hooks** | Prevents committing credential files |
| **Pluggable** | Custom rules and flexible configuration |
| **Documentation** | Each rule describes why it detects something as secret |

## Quick Start

### Installation Options

```bash
# Option 1: Local installation (recommended for projects)
./.agent/scripts/secretlint-helper.sh install

# Option 2: Quick scan without installation
./.agent/scripts/secretlint-helper.sh quick

# Option 3: Docker (no Node.js required)
./.agent/scripts/secretlint-helper.sh docker

# Option 4: Global installation
./.agent/scripts/secretlint-helper.sh install global
```

### Basic Usage

```bash
# Check installation status
./.agent/scripts/secretlint-helper.sh status

# Initialize configuration
./.agent/scripts/secretlint-helper.sh init

# Scan all files
./.agent/scripts/secretlint-helper.sh scan

# Scan specific directory
./.agent/scripts/secretlint-helper.sh scan "src/**/*"

# Quick scan (no installation needed)
./.agent/scripts/secretlint-helper.sh quick

# Scan via Docker
./.agent/scripts/secretlint-helper.sh docker
```

## Detected Secret Types

Secretlint's recommended preset detects:

| Secret Type | Rule |
|-------------|------|
| AWS Access Keys & Secret Keys | `@secretlint/secretlint-rule-aws` |
| GCP Service Account Keys | `@secretlint/secretlint-rule-gcp` |
| GitHub Tokens (PAT, OAuth, App) | `@secretlint/secretlint-rule-github` |
| npm Tokens | `@secretlint/secretlint-rule-npm` |
| Private Keys (RSA, DSA, EC, OpenSSH) | `@secretlint/secretlint-rule-privatekey` |
| Basic Auth in URLs | `@secretlint/secretlint-rule-basicauth` |
| Slack Tokens & Webhooks | `@secretlint/secretlint-rule-slack` |
| SendGrid API Keys | `@secretlint/secretlint-rule-sendgrid` |
| Shopify API Keys | `@secretlint/secretlint-rule-shopify` |
| OpenAI API Keys | `@secretlint/secretlint-rule-openai` |
| Anthropic/Claude API Keys | `@secretlint/secretlint-rule-anthropic` |
| Linear API Keys | `@secretlint/secretlint-rule-linear` |
| 1Password Service Account Tokens | `@secretlint/secretlint-rule-1password` |
| Database Connection Strings | `@secretlint/secretlint-rule-database-connection-string` |

### Additional Rules

| Rule | Description |
|------|-------------|
| `@secretlint/secretlint-rule-pattern` | Custom regex patterns |
| `@secretlint/secretlint-rule-secp256k1-privatekey` | Cryptocurrency private keys |
| `@secretlint/secretlint-rule-no-k8s-kind-secret` | Kubernetes Secret manifests |
| `@secretlint/secretlint-rule-no-homedir` | Home directory paths |
| `@secretlint/secretlint-rule-no-dotenv` | .env file detection |
| `@secretlint/secretlint-rule-filter-comments` | Comment-based ignoring |

## Configuration

### Basic Configuration (.secretlintrc.json)

```json
{
  "rules": [
    {
      "id": "@secretlint/secretlint-rule-preset-recommend"
    }
  ]
}
```

### Advanced Configuration

```json
{
  "rules": [
    {
      "id": "@secretlint/secretlint-rule-preset-recommend",
      "rules": [
        {
          "id": "@secretlint/secretlint-rule-aws",
          "options": {
            "allows": ["/test-key-/i", "AKIAIOSFODNN7EXAMPLE"]
          },
          "allowMessageIds": ["AWSAccountID"]
        },
        {
          "id": "@secretlint/secretlint-rule-github",
          "disabled": false
        }
      ]
    },
    {
      "id": "@secretlint/secretlint-rule-pattern",
      "options": {
        "patterns": [
          {
            "name": "custom-api-key",
            "patterns": ["/MY_CUSTOM_KEY=[A-Za-z0-9]{32}/"]
          }
        ]
      }
    }
  ]
}
```

### Rule Options

| Option | Type | Description |
|--------|------|-------------|
| `id` | string | Rule package name |
| `options` | object | Rule-specific options |
| `disabled` | boolean | Disable the rule |
| `allowMessageIds` | string[] | Message IDs to suppress |
| `allows` | string[] | Patterns to allow (RegExp-like strings) |

### Ignore File (.secretlintignore)

Uses `.gitignore` syntax:

```text
# Dependencies
**/node_modules/**
**/vendor/**

# Build outputs
**/dist/**
**/build/**

# Test fixtures (may contain fake secrets)
**/test/fixtures/**
**/testdata/**

# Generated files
**/package-lock.json
**/pnpm-lock.yaml

# Binary files
**/*.png
**/*.jpg
**/*.pdf
```

## Ignoring by Comments

Use inline comments to ignore specific lines:

```javascript
// secretlint-disable-next-line
const API_KEY = "sk-test-12345";

const config = {
  key: "secret-value" // secretlint-disable-line
};

// secretlint-disable
// Block of code with test secrets
const TEST_KEYS = {
  aws: "AKIAIOSFODNN7EXAMPLE",
  github: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
};
// secretlint-enable

/* secretlint-disable @secretlint/secretlint-rule-github -- test credentials */
const testToken = "ghs_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
/* secretlint-enable @secretlint/secretlint-rule-github */
```

## Output Formats

### Stylish (default)

```bash
secretlint "**/*"
```

### JSON

```bash
secretlint "**/*" --format json
# or
./.agent/scripts/secretlint-helper.sh scan . json
```

### SARIF (for CI/CD)

```bash
# Install SARIF formatter
npm install @secretlint/secretlint-formatter-sarif --save-dev

# Generate SARIF
secretlint "**/*" --format @secretlint/secretlint-formatter-sarif > results.sarif
# or
./.agent/scripts/secretlint-helper.sh sarif
```

### Mask Result (fix secrets)

```bash
# Mask secrets in a file and overwrite
secretlint .zsh_history --format=mask-result --output=.zsh_history
# or
./.agent/scripts/secretlint-helper.sh mask .env.example
```

## Pre-commit Integration

### Option 1: Native Git Hook

```bash
# Setup via helper
./.agent/scripts/secretlint-helper.sh hook
```

### Option 2: Husky + lint-staged (Node.js projects)

```bash
# Setup via helper
./.agent/scripts/secretlint-helper.sh husky
```

Or manually:

```bash
# Install
npx husky-init && npm install lint-staged --save-dev

# Configure lint-staged in package.json
{
  "lint-staged": {
    "*": ["secretlint"]
  }
}

# Add hook
npx husky add .husky/pre-commit "npx --no-install lint-staged"
```

### Option 3: pre-commit Framework (Docker)

```yaml
# .pre-commit-config.yaml
- repo: local
  hooks:
    - id: secretlint
      name: secretlint
      language: docker_image
      entry: secretlint/secretlint:latest secretlint
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Secretlint
on: [push, pull_request]
permissions:
  contents: read
jobs:
  secretlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx secretlint "**/*"
```

### GitHub Actions (Diff Only)

```yaml
name: Secretlint Diff
on: [push, pull_request]
jobs:
  secretlint-diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: tj-actions/changed-files@v44
        id: changed-files
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - if: steps.changed-files.outputs.any_changed == 'true'
        run: |
          npm ci
          npx secretlint ${{ steps.changed-files.outputs.all_changed_files }}
```

### GitLab CI

```yaml
secretlint:
  image: secretlint/secretlint:latest
  script:
    - secretlint "**/*"
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

### Generic CI Script

```bash
#!/bin/bash
set -e

# Install
npm ci

# Run secretlint
npx secretlint "**/*" --format json > secretlint-results.json || true

# Check for issues
if jq -e '.messages | length > 0' secretlint-results.json > /dev/null; then
    echo "Secrets detected!"
    jq '.messages[] | "\(.filePath):\(.line):\(.column) \(.ruleId): \(.message)"' secretlint-results.json
    exit 1
fi

echo "No secrets found"
```

## Docker Usage

### Quick Scan

```bash
docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm -it secretlint/secretlint secretlint "**/*"
```

### With Custom Config

```bash
docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm -it \
  secretlint/secretlint secretlint "**/*" \
  --secretlintrc .secretlintrc.json
```

### Built-in Docker Packages

The Docker image includes:
- `@secretlint/secretlint-rule-preset-recommend`
- `@secretlint/secretlint-rule-pattern`
- `@secretlint/secretlint-formatter-sarif`

## Comparison with Other Tools

| Feature | Secretlint | git-secrets | detect-secrets | Gitleaks |
|---------|------------|-------------|----------------|----------|
| Approach | Opt-in | Opt-out | Opt-out | Opt-out |
| Custom Rules | npm packages | Shell patterns | Python plugins | TOML config |
| Pre-commit | Yes | Yes | Yes | Yes |
| CI/CD | Yes | Yes | Yes | Yes |
| Documentation | Per-rule docs | Limited | Limited | Limited |
| Node.js Required | Yes (or Docker) | No | Python | No |
| False Positives | Lower (opt-in) | Higher | Medium | Medium |

## Best Practices

### For Development Teams

1. **Install locally** in each project for consistent behavior
2. **Initialize configuration** early in project setup
3. **Use pre-commit hooks** to catch secrets before they're committed
4. **Configure allowlists** for known safe patterns (test credentials)
5. **Document exceptions** with `secretlint-disable` comments

### For CI/CD

1. **Fail builds** when secrets are detected
2. **Generate SARIF** for security dashboard integration
3. **Scan diff only** in PRs for performance
4. **Use Docker** for consistent, dependency-free scanning

### Handling False Positives

1. **Allow specific patterns** in rule options:

   ```json
   {
     "options": {
       "allows": ["/test-/i", "example-key"]
     }
   }
   ```

2. **Suppress specific message IDs**:

   ```json
   {
     "allowMessageIds": ["AWSAccountID"]
   }
   ```

3. **Use inline comments** for one-off exceptions:

   ```javascript
   const key = "test-key"; // secretlint-disable-line
   ```

4. **Add to ignore file** for entire files/directories

## Integration with AI DevOps Framework

### Helper Script Commands

```bash
# Installation
./.agent/scripts/secretlint-helper.sh install         # Local install
./.agent/scripts/secretlint-helper.sh install global  # Global install
./.agent/scripts/secretlint-helper.sh install-rules all  # Additional rules

# Configuration
./.agent/scripts/secretlint-helper.sh init            # Initialize config
./.agent/scripts/secretlint-helper.sh status          # Check status

# Scanning
./.agent/scripts/secretlint-helper.sh scan            # Scan all files
./.agent/scripts/secretlint-helper.sh scan "src/**/*" # Scan specific
./.agent/scripts/secretlint-helper.sh quick           # Quick scan (npx)
./.agent/scripts/secretlint-helper.sh docker          # Docker scan

# Output
./.agent/scripts/secretlint-helper.sh scan . json     # JSON output
./.agent/scripts/secretlint-helper.sh sarif           # SARIF output
./.agent/scripts/secretlint-helper.sh mask file.txt   # Mask secrets

# Hooks
./.agent/scripts/secretlint-helper.sh hook            # Git hook
./.agent/scripts/secretlint-helper.sh husky           # Husky setup
```

### Quality Pipeline Integration

Secretlint integrates with the framework's quality pipeline:

```bash
# Run as part of quality checks
./.agent/scripts/quality-check.sh  # Includes secretlint

# Pre-commit validation
./.agent/scripts/pre-commit-hook.sh  # Includes secretlint
```

## Troubleshooting

### Common Issues

**"No configuration file found"**

```bash
./.agent/scripts/secretlint-helper.sh init
```

**"secretlint command not found"**

```bash
# Use npx
npx secretlint "**/*"
# Or install globally
npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
```

**Performance issues with large repos**

```bash
# Configure .secretlintignore to exclude:
**/node_modules/**
**/dist/**
**/*.lock
```

**False positives**

```json
{
  "rules": [{
    "id": "@secretlint/secretlint-rule-preset-recommend",
    "rules": [{
      "id": "@secretlint/secretlint-rule-<rule-name>",
      "options": {
        "allows": ["/pattern-to-allow/i"]
      }
    }]
  }]
}
```

## Resources

- **GitHub**: [https://github.com/secretlint/secretlint](https://github.com/secretlint/secretlint)
- **npm**: [https://www.npmjs.com/package/secretlint](https://www.npmjs.com/package/secretlint)
- **Docker Hub**: [https://hub.docker.com/r/secretlint/secretlint](https://hub.docker.com/r/secretlint/secretlint)
- **Demo**: [https://secretlint.github.io/](https://secretlint.github.io/)

---

**Secretlint provides a secure, developer-friendly approach to preventing credential leaks with its opt-in rule system and comprehensive documentation.**
