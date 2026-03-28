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
- **Init**: `npx secretlint --init` creates `.secretlintrc.json` with `{ "rules": [{ "id": "@secretlint/secretlint-rule-preset-recommend" }] }`
- **Config**: `.secretlintrc.json` (rules), `.secretlintignore` (exclusions)
- **Helper**: `secretlint-helper.sh [install|init|scan|quick|docker|mask|sarif|hook|status|help]`
- **Exit codes**: 0=clean, 1=secrets found, 2=error
- **Output formats**: stylish (default), json, compact, table, sarif, mask-result
- **Pre-commit**: Husky+lint-staged or native git hooks supported
- **Quality pipeline**: `linters-local.sh` and `pre-commit-hook.sh` both include secretlint

<!-- AI-CONTEXT-END -->

## Quick Start

```bash
secretlint-helper.sh install        # Local install (recommended)
secretlint-helper.sh quick          # Quick scan without installation
secretlint-helper.sh docker         # Docker (no Node.js required)
secretlint-helper.sh status         # Check installation status
secretlint-helper.sh init           # Initialize configuration
secretlint-helper.sh scan           # Scan all files
secretlint-helper.sh scan "src/**/*"  # Scan specific directory
```

## Detected Secret Types

**Preset rules** (`@secretlint/secretlint-rule-preset-recommend`): AWS keys (`-rule-aws`), GCP service accounts (`-rule-gcp`), GitHub tokens (`-rule-github`), npm tokens (`-rule-npm`), private keys (`-rule-privatekey`), basic auth in URLs (`-rule-basicauth`), Slack tokens/webhooks (`-rule-slack`), SendGrid (`-rule-sendgrid`), Shopify (`-rule-shopify`), OpenAI (`-rule-openai`), Anthropic/Claude (`-rule-anthropic`), Linear (`-rule-linear`), 1Password (`-rule-1password`), database connection strings (`-rule-database-connection-string`).

**Additional rules**: `@secretlint/secretlint-rule-pattern` (custom regex), `secretlint-rule-secp256k1-privatekey` (crypto keys), `secretlint-rule-no-k8s-kind-secret` (Kubernetes), `secretlint-rule-no-homedir`, `secretlint-rule-no-dotenv`, `secretlint-rule-filter-comments`.

## Configuration

### Advanced (.secretlintrc.json)

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

**Rule options**: `id` (package name), `options` (rule-specific), `disabled` (boolean), `allowMessageIds` (string[] -- suppress specific message IDs), `allows` (string[] -- RegExp-like patterns to allow).

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
**/*.{png,jpg,pdf}
```

### Inline Directives

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
secretlint "**/*"                                                              # Stylish (default)
secretlint "**/*" --format json                                                # JSON
secretlint "**/*" --format @secretlint/secretlint-formatter-sarif > out.sarif  # SARIF (CI dashboards)
secretlint .zsh_history --format=mask-result --output=.zsh_history             # Mask secrets in file
# Via helper
secretlint-helper.sh scan . json   # JSON
secretlint-helper.sh sarif         # SARIF (requires @secretlint/secretlint-formatter-sarif)
secretlint-helper.sh mask .env.example
```

## Pre-commit Integration

```bash
secretlint-helper.sh hook   # Native git hook
secretlint-helper.sh husky  # Husky + lint-staged (Node.js projects)
# Manual husky: npx husky-init && npm install lint-staged --save-dev
# package.json: "lint-staged": { "*": ["secretlint"] }
# .husky/pre-commit: npx --no-install lint-staged
```

**pre-commit framework (Docker):**

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
      # For diff-only scanning: add fetch-depth: 0, tj-actions/changed-files@v44,
      # then pass changed files list instead of "**/*"
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx secretlint "**/*"
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
docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm -it secretlint/secretlint secretlint "**/*"
# With custom config: append --secretlintrc .secretlintrc.json
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

| Error | Fix |
|-------|-----|
| `secretlint-rule-preset-recommend is not found` | `npm install --save-dev secretlint @secretlint/secretlint-rule-preset-recommend` |
| `No configuration file found` | `secretlint-helper.sh init` |
| `secretlint command not found` | `npx secretlint "**/*"` or `npm install -g secretlint @secretlint/secretlint-rule-preset-recommend` |
| Exit code 2 (config/install error) | `secretlint-helper.sh status`; reinstall or `rm .secretlintrc.json && secretlint-helper.sh init` |

**Performance**: add to `.secretlintignore`: `**/node_modules/**`, `**/dist/**`, `**/*.lock`

**False positives**: allow patterns in rule `options.allows` (see Advanced config above) or use inline `// secretlint-disable-line`

## Resources

- **GitHub**: https://github.com/secretlint/secretlint
- **npm**: https://www.npmjs.com/package/secretlint
- **Docker Hub**: https://hub.docker.com/r/secretlint/secretlint
- **Demo**: https://secretlint.github.io/
