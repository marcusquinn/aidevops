---
description: Secretlint for detecting exposed secrets
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

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

## Quick Start

```bash
./.agents/scripts/secretlint-helper.sh install   # Local install (recommended)
./.agents/scripts/secretlint-helper.sh quick     # Quick scan without installation
./.agents/scripts/secretlint-helper.sh docker    # Docker (no Node.js required)
./.agents/scripts/secretlint-helper.sh install global  # Global installation

./.agents/scripts/secretlint-helper.sh status    # Check installation status
./.agents/scripts/secretlint-helper.sh init      # Initialize configuration
./.agents/scripts/secretlint-helper.sh scan      # Scan all files
./.agents/scripts/secretlint-helper.sh scan "src/**/*"  # Scan specific directory
```

## Detected Secret Types

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

**Additional rules**: `@secretlint/secretlint-rule-pattern` (custom regex), `secretlint-rule-secp256k1-privatekey` (crypto keys), `secretlint-rule-no-k8s-kind-secret` (Kubernetes), `secretlint-rule-no-homedir`, `secretlint-rule-no-dotenv`, `secretlint-rule-filter-comments`.

## Configuration

### Basic (.secretlintrc.json)

```json
{
  "rules": [
    { "id": "@secretlint/secretlint-rule-preset-recommend" }
  ]
}
```

### Advanced

```json
{
  "rules": [
    {
      "id": "@secretlint/secretlint-rule-preset-recommend",
      "rules": [
        {
          "id": "@secretlint/secretlint-rule-aws",
          "options": { "allows": ["/test-key-/i", "AKIAIOSFODNN7EXAMPLE"] },
          "allowMessageIds": ["AWSAccountID"]
        }
      ]
    },
    {
      "id": "@secretlint/secretlint-rule-pattern",
      "options": {
        "patterns": [{ "name": "custom-api-key", "patterns": ["/MY_CUSTOM_KEY=[A-Za-z0-9]{32}/"] }]
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

```text
**/node_modules/**
**/vendor/**
**/dist/**
**/build/**
**/test/fixtures/**
**/testdata/**
**/package-lock.json
**/pnpm-lock.yaml
**/*.png
**/*.jpg
**/*.pdf
```

## Ignoring by Comments

```javascript
// secretlint-disable-next-line
const API_KEY = "sk-test-12345";

const config = { key: "secret-value" }; // secretlint-disable-line

// secretlint-disable
const TEST_KEYS = { aws: "AKIAIOSFODNN7EXAMPLE" };
// secretlint-enable

/* secretlint-disable @secretlint/secretlint-rule-github -- test credentials */
const testToken = "ghs_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
/* secretlint-enable @secretlint/secretlint-rule-github */
```

## Output Formats

```bash
secretlint "**/*"                                          # Stylish (default)
secretlint "**/*" --format json                            # JSON
./.agents/scripts/secretlint-helper.sh scan . json        # JSON via helper

# SARIF (for CI/CD security dashboards)
npm install @secretlint/secretlint-formatter-sarif --save-dev
secretlint "**/*" --format @secretlint/secretlint-formatter-sarif > results.sarif
./.agents/scripts/secretlint-helper.sh sarif              # Via helper

# Mask secrets in a file
secretlint .zsh_history --format=mask-result --output=.zsh_history
./.agents/scripts/secretlint-helper.sh mask .env.example  # Via helper
```

## Pre-commit Integration

```bash
# Option 1: Native git hook
./.agents/scripts/secretlint-helper.sh hook

# Option 2: Husky + lint-staged (Node.js projects)
./.agents/scripts/secretlint-helper.sh husky
# Or manually:
npx husky-init && npm install lint-staged --save-dev
# Add to package.json: "lint-staged": { "*": ["secretlint"] }
# npx husky add .husky/pre-commit "npx --no-install lint-staged"
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
        with: { node-version: 20 }
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
        with: { fetch-depth: 0 }
      - uses: tj-actions/changed-files@v44
        id: changed-files
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - if: steps.changed-files.outputs.any_changed == 'true'
        run: |
          npm ci
          npx secretlint ${{ steps.changed-files.outputs.all_changed_files }}
```

### GitLab CI

```yaml
secretlint:
  image: secretlint/secretlint:latest
  script: secretlint "**/*"
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

## Docker Usage

```bash
# Quick scan
docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm -it secretlint/secretlint secretlint "**/*"

# With custom config
docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm -it \
  secretlint/secretlint secretlint "**/*" --secretlintrc .secretlintrc.json
```

Docker image includes: `secretlint-rule-preset-recommend`, `secretlint-rule-pattern`, `secretlint-formatter-sarif`.

## Comparison with Other Tools

| Feature | Secretlint | git-secrets | detect-secrets | Gitleaks |
|---------|------------|-------------|----------------|----------|
| Approach | Opt-in | Opt-out | Opt-out | Opt-out |
| Custom Rules | npm packages | Shell patterns | Python plugins | TOML config |
| Documentation | Per-rule docs | Limited | Limited | Limited |
| Node.js Required | Yes (or Docker) | No | Python | No |
| False Positives | Lower (opt-in) | Higher | Medium | Medium |

## Troubleshooting

**"Failed to load rule module: @secretlint/secretlint-rule-preset-recommend is not found"**

```bash
npm install --save-dev secretlint @secretlint/secretlint-rule-preset-recommend
./.agents/scripts/secretlint-helper.sh status
```

**"No configuration file found"**

```bash
./.agents/scripts/secretlint-helper.sh init
```

**"secretlint command not found"**

```bash
npx secretlint "**/*"
# Or: npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
```

**Exit code 2** (configuration/installation error, not secrets found):

```bash
./.agents/scripts/secretlint-helper.sh status
./.agents/scripts/secretlint-helper.sh install   # Missing rules
rm .secretlintrc.json && ./.agents/scripts/secretlint-helper.sh init  # Invalid config
```

**Performance issues with large repos** — add to `.secretlintignore`:

```text
**/node_modules/**
**/dist/**
**/*.lock
```

**False positives** — allow specific patterns in rule options:

```json
{
  "rules": [{
    "id": "@secretlint/secretlint-rule-preset-recommend",
    "rules": [{
      "id": "@secretlint/secretlint-rule-<rule-name>",
      "options": { "allows": ["/pattern-to-allow/i"] },
      "allowMessageIds": ["AWSAccountID"]
    }]
  }]
}
```

Or use inline comments: `const key = "test-key"; // secretlint-disable-line`

## Quality Pipeline Integration

```bash
./.agents/scripts/linters-local.sh      # Includes secretlint
./.agents/scripts/pre-commit-hook.sh    # Includes secretlint
```

## Resources

- **GitHub**: https://github.com/secretlint/secretlint
- **npm**: https://www.npmjs.com/package/secretlint
- **Docker Hub**: https://hub.docker.com/r/secretlint/secretlint
- **Demo**: https://secretlint.github.io/
