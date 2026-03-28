---
description: Interactive per-repo testing infrastructure setup with bundle-aware defaults
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

Configure testing infrastructure for the current project. Detects the project bundle, discovers existing test tooling, identifies gaps, and generates configuration with bundle-aware defaults.

Arguments: $ARGUMENTS

## Purpose

Most repos have ad-hoc testing. This command provides structured onboarding: detect project type, discover existing infrastructure, identify gaps against bundle-recommended quality gates, generate configuration, and verify end-to-end. The output is a working test configuration — not a plan.

## Workflow

### Step 1: Detect Project Bundle

```bash
BUNDLE=$(~/.aidevops/agents/scripts/bundle-helper.sh resolve .)
BUNDLE_NAME=$(echo "$BUNDLE" | jq -r '.name')
QUALITY_GATES=$(echo "$BUNDLE" | jq -r '.quality_gates[]')
SKIP_GATES=$(echo "$BUNDLE" | jq -r '.skip_gates[]' 2>/dev/null)
```

Display detected bundle and quality gates. If no bundle detected, fall back to `cli-tool` (most conservative). Let user override:

```text
Override bundle? [Enter to accept, or type bundle name]
1. web-app (detected)  2. cli-tool  3. library
4. infrastructure      5. content-site  6. agent
```

### Step 2: Discover Existing Test Infrastructure

Run `testing-setup-helper.sh discover .` to scan for existing tooling:

| Category | What to find | How |
|----------|-------------|-----|
| Test runners | jest, vitest, pytest, cargo test, go test, bats | `package.json` scripts/devDeps, `pyproject.toml`, `Cargo.toml`, `go.mod`, `*.bats` files |
| Test directories | `tests/`, `test/`, `__tests__/`, `spec/`, `*_test.go` | Directory/file existence |
| Test configs | `jest.config.*`, `vitest.config.*`, `pytest.ini`, `.bats` | File glob |
| CI pipelines | `.github/workflows/`, `.gitlab-ci.yml` | File existence, grep for test steps |
| Linter configs | `.eslintrc*`, `.prettierrc*`, `tsconfig.json`, `.shellcheckrc` | File glob |
| Coverage configs | `.nycrc`, `coverage/`, `jest --coverage`, `c8`, `istanbul` | Config files, package.json scripts |
| E2E/integration | `playwright.config.*`, `cypress.config.*`, `*.spec.ts` | File glob |
| Quality gates | `linters-local.sh` integration, pre-commit hooks | Not yet detected (TODO: t1660.2+) |

Display results as `[found]`/`[missing]` status table with source details.

### Step 3: Gap Analysis

Compare discovered infrastructure against bundle quality gates:

| Gate Status | Action |
|-------------|--------|
| **found + configured** | Verify it runs: execute test command, report pass/fail |
| **found + misconfigured** | Show what's wrong, offer to fix |
| **missing + recommended** | Offer to install and configure |
| **missing + skipped** | Note as intentionally skipped by bundle |

Present as actionable summary grouped by: Ready, Needs attention, Missing (recommended), Skipped by bundle.

### Step 4: Interactive Configuration

For each gap, walk through configuration interactively. Pattern for each item:

```text
Install <tool>? Bundle '<bundle>' recommends it for <purpose>.
1. Yes — install and create config (recommended)
2. Skip — I'll handle this manually
3. Use <alternative> instead — already installed
```

**Configuration categories:**

- **Missing test runner** — install dependency, create minimal config, create sample test if none exist, add `test` script to package.json
- **Missing coverage** — configure c8/istanbul with 80% threshold (or custom)
- **Missing CI integration** — add test step to existing workflow or create new one
- **Pre-commit hooks** — install aidevops hooks or husky/lint-staged

> **Note:** Runner installation is agent-driven (requires judgment for choosing alternatives, handling conflicts). The helper provides `discover`, `gaps`, `status`, and `verify` — the deterministic parts.

### Step 5: Generate Configuration

After collecting choices, create all configuration files directly:

- Test runner configs (vitest.config.ts, jest.config.js, pytest.ini, etc.)
- Coverage configs (.nycrc, c8 config in vitest.config.ts, etc.)
- CI workflow additions (test job in GitHub Actions)
- Pre-commit hook installation
- `.aidevops-testing.json` — project-level testing metadata:

```json
{
  "bundle": "web-app",
  "configured_at": "2026-03-26T12:00:00Z",
  "test_runners": ["vitest"],
  "quality_gates": ["eslint", "prettier", "typescript-check", "vitest"],
  "coverage": { "enabled": true, "threshold": 80 },
  "ci_integration": true,
  "pre_commit_hooks": true
}
```

### Step 6: Verification

```bash
testing-setup-helper.sh verify .
```

Executes each configured runner and reports `[pass]`/`[fail]`/`[skip]` per gate.

### Step 7: Summary

Display what was configured, files created/modified, and next steps:

1. Write tests for existing code
2. Run `testing-setup-helper.sh status` to check test health
3. Push to trigger CI pipeline test step
4. Consider `/testing-coverage` to identify untested code paths

## Options

| Option | Description |
|--------|-------------|
| `--bundle <name>` | Override auto-detected bundle |
| `--non-interactive` | Accept all defaults without prompting |
| `--dry-run` | Show what would be configured without making changes |
| `--skip-install` | Configure files only, don't install packages |
| `--verify-only` | Run verification on existing setup without changes |

## Bundle-to-Runner Mapping

| Bundle | Primary Runner | Secondary | Coverage Tool |
|--------|---------------|-----------|---------------|
| `web-app` | vitest | playwright | c8 |
| `library` | vitest | — | c8 |
| `cli-tool` | bats / bash tests | — | kcov |
| `agent` | agent-test-helper.sh | bash tests | — |
| `infrastructure` | terraform validate | — | — |
| `content-site` | playwright | lighthouse | — |

## Related

- `tools/build-agent/agent-testing.md` — Agent-specific testing framework
- `bundles/*.json` — Bundle definitions with quality gates
- `.agents/scripts/linters-local.sh` — Local quality checks (run directly, not via `scripts/linters-local.sh`)
- `.agents/scripts/bundle-helper.sh` — Bundle detection and resolution
- `workflows/preflight.md` — Pre-commit quality workflow
