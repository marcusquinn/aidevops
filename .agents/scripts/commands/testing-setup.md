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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Configure testing infrastructure for the current project. Detects bundle, discovers existing tooling, identifies gaps against bundle quality gates, generates configuration, and verifies end-to-end.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Detect Project Bundle

```bash
BUNDLE=$(~/.aidevops/agents/scripts/bundle-helper.sh resolve .)
BUNDLE_NAME=$(echo "$BUNDLE" | jq -r '.name')
QUALITY_GATES=$(echo "$BUNDLE" | jq -r '.quality_gates[]')
SKIP_GATES=$(echo "$BUNDLE" | jq -r '.skip_gates[]' 2>/dev/null)
```

Display detected bundle and quality gates. No bundle → fall back to `cli-tool`. Offer override (web-app, cli-tool, library, infrastructure, content-site, agent).

### Step 2: Discover Existing Infrastructure

Run `testing-setup-helper.sh discover .` to scan:

| Category | What to find | How |
|----------|-------------|-----|
| Test runners | jest, vitest, pytest, cargo test, go test, bats | `package.json` scripts/devDeps, `pyproject.toml`, `Cargo.toml`, `go.mod`, `*.bats` |
| Test directories | `tests/`, `test/`, `__tests__/`, `spec/`, `*_test.go` | Directory/file existence |
| Test configs | `jest.config.*`, `vitest.config.*`, `pytest.ini`, `.bats` | File glob |
| CI pipelines | `.github/workflows/`, `.gitlab-ci.yml` | File existence, grep for test steps |
| Linter configs | `.eslintrc*`, `.prettierrc*`, `tsconfig.json`, `.shellcheckrc` | File glob |
| Coverage configs | `.nycrc`, `coverage/`, `jest --coverage`, `c8`, `istanbul` | Config files, package.json scripts |
| E2E/integration | `playwright.config.*`, `cypress.config.*`, `*.spec.ts` | File glob |

Display `[found]`/`[missing]` status table with source details.

### Step 3: Gap Analysis

Compare discovered infrastructure against bundle quality gates:

| Gate Status | Action |
|-------------|--------|
| **found + configured** | Verify it runs — execute test command, report pass/fail |
| **found + misconfigured** | Show what's wrong, offer to fix |
| **missing + recommended** | Offer to install and configure |
| **missing + skipped** | Note as intentionally skipped by bundle |

Group results: Ready, Needs attention, Missing (recommended), Skipped by bundle.

### Step 4: Interactive Configuration

For each gap, offer: (1) install and configure (recommended), (2) skip — handle manually, (3) use alternative already installed.

**Categories:** missing test runner (install dep, create config, sample test, add `test` script), missing coverage (c8/istanbul, 80% threshold default), missing CI integration (add test step to workflow), pre-commit hooks (aidevops hooks or husky/lint-staged).

> Runner installation is agent-driven (requires judgment for alternatives, conflict handling). The helper provides `discover`, `gaps`, `status`, `verify` — the deterministic parts.

### Step 5: Generate Configuration

Create all configuration files from collected choices: test runner configs, coverage configs, CI workflow additions, pre-commit hooks, and `.aidevops-testing.json`:

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

### Step 6: Verify and Summarize

```bash
testing-setup-helper.sh verify .
```

Execute each configured runner — report `[pass]`/`[fail]`/`[skip]` per gate. Then display files created/modified and next steps:

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
