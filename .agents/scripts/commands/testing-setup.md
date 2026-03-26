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

Most repos have ad-hoc testing — some scripts, maybe a runner, but no consistent structure. This command provides a structured onboarding flow that:

1. Detects the project type via bundle system
2. Discovers what testing infrastructure already exists
3. Identifies gaps between current state and bundle-recommended quality gates
4. Generates configuration files and scripts to fill those gaps
5. Verifies the setup works end-to-end

The output is a working test configuration — not a plan or recommendation.

## Workflow

### Step 1: Detect Project Bundle

```bash
BUNDLE=$(~/.aidevops/agents/scripts/bundle-helper.sh resolve .)
BUNDLE_NAME=$(echo "$BUNDLE" | jq -r '.name')
QUALITY_GATES=$(echo "$BUNDLE" | jq -r '.quality_gates[]')
SKIP_GATES=$(echo "$BUNDLE" | jq -r '.skip_gates[]' 2>/dev/null)
```

Display the detected bundle and its quality gates:

```text
Project type: web-app (auto-detected from package.json, tsconfig.json)
Quality gates: eslint, prettier, typescript-check, secretlint, jest, vitest
Skipped gates: shellcheck, shfmt, return-statements, positional-parameters
```

If no bundle is detected, fall back to `cli-tool` (most conservative). If the user disagrees with the detection, let them override:

```text
Override bundle? [Enter to accept, or type bundle name]
1. web-app (detected)
2. cli-tool
3. library
4. infrastructure
5. content-site
6. agent
```

### Step 2: Discover Existing Test Infrastructure

Run `testing-setup-helper.sh discover .` to scan the project for existing test tooling:

**Detection targets:**

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

Display results as a status table:

```text
=== Existing Test Infrastructure ===

  [found]   jest (package.json devDependencies)
  [found]   eslint (eslintrc.json)
  [found]   prettier (.prettierrc)
  [found]   tests/ directory (12 test files)
  [missing] vitest (bundle recommends, not installed)
  [missing] coverage configuration
  [missing] CI test step in workflows
  [missing] pre-commit hooks
```

### Step 3: Gap Analysis

Compare discovered infrastructure against bundle quality gates. For each gate:

| Gate Status | Action |
|-------------|--------|
| **found + configured** | Verify it runs: execute the test command, report pass/fail |
| **found + misconfigured** | Show what's wrong, offer to fix |
| **missing + recommended** | Offer to install and configure |
| **missing + skipped** | Note as intentionally skipped by bundle |

Present the gap analysis as an actionable summary:

```text
=== Gap Analysis ===

Ready (2):
  eslint — configured, 0 errors on last run
  prettier — configured, all files formatted

Needs attention (2):
  jest — installed but no config file, tests may not run correctly
  typescript-check — tsconfig.json exists but strict mode disabled

Missing (recommended by bundle) (1):
  vitest — not installed, bundle recommends for unit testing

Skipped by bundle (2):
  shellcheck — not relevant for web-app projects
  shfmt — not relevant for web-app projects
```

### Step 4: Interactive Configuration

For each gap, walk through configuration:

**4a. Missing test runner installation:**

```text
Install vitest? Bundle 'web-app' recommends it for unit testing.
1. Yes — install and create vitest.config.ts (recommended)
2. Skip — I'll handle this manually
3. Use jest instead — already installed
```

If yes, the agent performs the installation directly:
- Adds the dependency (`npm install -D vitest` / `pip install pytest` / etc.)
- Creates a minimal config file from templates
- Creates a sample test file if no tests exist
- Adds a `test` script to package.json (if applicable)

> **Note:** Runner installation is agent-driven (the agent runs the appropriate
> package manager commands), not a helper subcommand. The helper provides
> `discover`, `gaps`, `status`, and `verify` — the deterministic parts.
> Installation requires judgment (choosing between alternatives, handling
> conflicts) and is handled by the agent directly.

**4b. Missing coverage configuration:**

```text
Set up code coverage?
1. Yes — configure c8/istanbul with 80% threshold (recommended)
2. Yes — configure with custom threshold
3. Skip
```

**4c. Missing CI integration:**

```text
Add test step to CI pipeline?
1. Yes — add to existing .github/workflows/ (recommended)
2. Create new test workflow
3. Skip — I'll configure CI separately
```

**4d. Pre-commit hooks:**

```text
Install pre-commit quality hooks?
1. Yes — install aidevops hooks (recommended)
2. Yes — install husky/lint-staged
3. Skip
```

### Step 5: Generate Configuration

After collecting choices, generate all configuration files. The agent creates these directly:

- Test runner configs (vitest.config.ts, jest.config.js, pytest.ini, etc.)
- Coverage configs (.nycrc, c8 config in vitest.config.ts, etc.)
- CI workflow additions (test job in GitHub Actions)
- Pre-commit hook installation
- `.aidevops-testing.json` — project-level testing metadata for future commands

The `.aidevops-testing.json` file records what was configured:

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

Run the configured test stack to verify everything works:

```bash
testing-setup-helper.sh verify .
```

This executes each configured runner and reports results:

```text
=== Test Verification ===

  [pass] vitest
  [pass] eslint
  [pass] prettier
  [pass] typescript-check

  Results: 4 passed, 0 failed, 0 skipped
```

### Step 7: Summary and Next Steps

Display what was configured and suggest next steps:

```text
=== Testing Setup Complete ===

Configured: vitest, eslint, prettier, typescript-check, coverage (80%)
Files created: vitest.config.ts, .aidevops-testing.json
Files modified: package.json (added test scripts)

Next steps:
  1. Write tests for your existing code
  2. Run 'testing-setup-helper.sh status' to check test health
  3. Push to trigger CI pipeline test step
  4. Consider '/testing-coverage' to identify untested code paths
```

## Options

| Option | Description |
|--------|-------------|
| `--bundle <name>` | Override auto-detected bundle |
| `--non-interactive` | Accept all defaults without prompting |
| `--dry-run` | Show what would be configured without making changes |
| `--skip-install` | Configure files only, don't install packages |
| `--verify-only` | Run verification on existing setup without changes |

## Bundle-to-Runner Mapping

Default test runner recommendations per bundle:

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
